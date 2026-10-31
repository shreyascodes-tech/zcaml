//! The C runtime: `ocamlrun`, `libcamlrun`, `libasmrun`, `ocamlyacc`, plus the
//! generated headers / primitive tables everything else is built against.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const config_headers = @import("config_headers.zig");
const Tools = @import("tools/root.zig");

pub const Artifacts = struct {
    platform: Platform,
    /// Generated headers: `build_config.h` and `caml/{m,s,version,exec,opnames,jumptbl}.h`.
    headers_dir: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    ocamlyacc: *std.Build.Step.Compile,
    libcamlrun: *std.Build.Step.Compile,
    ocamlrun: *std.Build.Step.Compile,
    libasmrun: ?*std.Build.Step.Compile,
    libcomprmarsh: *std.Build.Step.Compile,
    zstd_lib: *std.Build.Step.Compile,

    /// Include paths for C code built against the runtime (runtime, stubs, ...).
    pub fn addIncludes(self: Artifacts, src: Source, mod: *std.Build.Module) void {
        mod.addIncludePath(self.headers_dir);
        mod.addIncludePath(self.headers_dir.path(src.b, "caml"));
        mod.addIncludePath(src.path("runtime"));
    }
};

pub const Options = struct {
    platform: Platform,
    optimize: std.builtin.OptimizeMode,
    /// Default stdlib location baked into `ocamlrun` (relative to its directory).
    stdlib_dir: []const u8 = "../lib/ocaml",
};

pub fn build(src: Source, options: Options) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const p = options.platform;
    const rt = m.runtime;
    const os_c_sources = if (p.is_windows) rt.win32_c_sources else rt.unix_c_sources;

    const zstd_lib = b.dependency("zstd", .{
        .target = p.resolved,
        .optimize = options.optimize,
        .pie = true,
    }).artifact("zstd");
    // OCaml links this archive through `zig cc`, not Zig's build linker.
    // Match the runtime's C flags and avoid a dependency on Zig's UBSan runtime.
    zstd_lib.root_module.sanitize_c = .off;

    // 1. Bytecode runtime sources (also scanned for primitives)
    const bytecode_c = runtimeSources(b, &.{ rt.common_c_sources, os_c_sources, rt.bytecode_only_c_sources }, null);
    const c_inputs = b.allocator.alloc(Tools.InputFile, bytecode_c.len) catch @panic("OOM");
    for (c_inputs, bytecode_c) |*in, rel| in.* = .of(src.path(rel));

    // 2. opnames.h, jumptbl.h, primitives, prims.c
    const gen, _ = Tools.run(b, .gen_runtime, .{
        .instruct_h = .of(src.path("runtime/caml/instruct.h")),
        .opnames_h = .of("opnames.h"),
        .jumptbl_h = .of("jumptbl.h"),
        .primitives = .of("primitives"),
        .prims_c = .of("prims.c"),
        .c_files = c_inputs,
    });

    // 3. Configuration headers
    const headers = b.addWriteFiles();
    _ = headers.add("caml/m.h", config_headers.machineH(src, p));
    _ = headers.add("caml/s.h", config_headers.systemH(src, p));
    _ = headers.add("caml/version.h", config_headers.versionH(src));
    _ = headers.add("caml/exec.h", config_headers.execH(src));
    _ = headers.add("build_config.h", config_headers.buildConfigH(b, p, options.stdlib_dir, p.runtimeId(b, m.version)));
    _ = headers.addCopyFile(gen.opnames_h.lazyPath(), "caml/opnames.h");
    _ = headers.addCopyFile(gen.jumptbl_h.lazyPath(), "caml/jumptbl.h");

    var self: Artifacts = .{
        .platform = p,
        .headers_dir = headers.getDirectory(),
        .primitives = gen.primitives.lazyPath(),
        .ocamlyacc = undefined,
        .libcamlrun = undefined,
        .ocamlrun = undefined,
        .libasmrun = null,
        .libcomprmarsh = undefined,
        .zstd_lib = zstd_lib,
    };

    const runtime_cflags = p.c.flags(b, &.{
        "-fno-common",
        "-DIN_CAML_RUNTIME",
        "-DCAMLDLLIMPORT=",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
    });
    const cflags = if (p.is_elf) ocamlcConcat(b, runtime_cflags, &.{"-ffunction-sections"}) else runtime_cflags;

    // 4. ocamlyacc
    self.ocamlyacc = b.addExecutable(.{
        .name = "ocamlyacc",
        .root_module = cModule(b, p, options.optimize, .{}),
    });
    self.addIncludes(src, self.ocamlyacc.root_module);
    self.ocamlyacc.root_module.addCSourceFiles(.{
        .root = src.path(""),
        .files = ocamlcConcat(b, if (p.is_windows) &.{"yacc/wstr.c"} else &.{}, rt.ocamlyacc_c_sources),
        .flags = p.c.flags(b, &.{ "-DNDEBUG", "-DCAMLDLLIMPORT=" }),
    });
    if (p.is_windows) self.ocamlyacc.mingw_unicode_entry_point = true;

    // 5. libcamlrun.a
    self.libcamlrun = b.addLibrary(.{
        .linkage = .static,
        .name = "camlrun",
        .root_module = cModule(b, p, options.optimize, .{}),
    });
    self.addIncludes(src, self.libcamlrun.root_module);
    self.libcamlrun.root_module.linkLibrary(zstd_lib);
    self.libcamlrun.root_module.addCSourceFiles(.{
        .root = src.path(""),
        .files = bytecode_c,
        .flags = cflags,
    });

    // 6. ocamlrun
    self.ocamlrun = b.addExecutable(.{
        .name = "ocamlrun",
        .root_module = cModule(b, p, options.optimize, .{}),
    });
    self.addIncludes(src, self.ocamlrun.root_module);
    self.ocamlrun.root_module.addCSourceFile(.{ .file = gen.prims_c.lazyPath(), .flags = cflags });
    self.ocamlrun.root_module.linkLibrary(self.libcamlrun);
    self.ocamlrun.root_module.linkLibrary(zstd_lib);
    p.c.linkLibs(self.ocamlrun.root_module);
    if (p.is_elf) self.ocamlrun.rdynamic = true;
    if (p.is_windows) self.ocamlrun.mingw_unicode_entry_point = true;

    // 7. libasmrun.a (targets with a native-code backend)
    if (p.runtimeAsmFile()) |asm_file| {
        const asmrun = b.addLibrary(.{
            .linkage = .static,
            .name = "asmrun",
            .root_module = cModule(b, p, options.optimize, .{}),
        });
        self.addIncludes(src, asmrun.root_module);
        asmrun.root_module.addCSourceFiles(.{
            .root = src.path(""),
            .files = runtimeSources(
                b,
                &.{ rt.common_c_sources, os_c_sources, rt.native_only_c_sources },
                if (std.mem.endsWith(u8, asm_file, ".S")) b.fmt("runtime/{s}", .{asm_file}) else null,
            ),
            .flags = ocamlcConcat(b, cflags, p.nativeDefines(b)),
        });
        self.libasmrun = asmrun;
    }

    // 8. libcomprmarsh.a
    self.libcomprmarsh = b.addLibrary(.{
        .linkage = .static,
        .name = "comprmarsh",
        .root_module = cModule(b, p, options.optimize, .{ .pic = true }),
    });
    self.addIncludes(src, self.libcomprmarsh.root_module);
    self.libcomprmarsh.root_module.linkLibrary(zstd_lib);
    self.libcomprmarsh.root_module.addCSourceFile(.{ .file = src.path("runtime/zstd.c"), .flags = cflags });

    return self;
}

pub const ModuleOptions = struct {
    pic: ?bool = null,
    strip: ?bool = null,
};

/// A C-only module for `p`.
pub fn cModule(b: *std.Build, p: Platform, optimize: std.builtin.OptimizeMode, opts: ModuleOptions) *std.Build.Module {
    return b.createModule(.{
        .target = p.resolved,
        .optimize = optimize,
        .link_libc = true,
        .pic = opts.pic,
        .strip = opts.strip,
    });
}

/// `runtime/<name>.c` for every name in `lists`, plus an optional extra file.
fn runtimeSources(b: *std.Build, lists: []const []const []const u8, extra: ?[]const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lists) |list| {
        for (list) |name| out.append(b.allocator, b.fmt("runtime/{s}.c", .{name})) catch @panic("OOM");
    }
    if (extra) |e| out.append(b.allocator, e) catch @panic("OOM");
    return out.items;
}

const ocamlcConcat = @import("ocamlc.zig").concat;
