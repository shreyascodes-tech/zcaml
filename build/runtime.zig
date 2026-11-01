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
    libcamlrun_pic: ?*std.Build.Step.Compile = null,
    libcamlrun_shared: ?*std.Build.Step.Compile = null,
    libcamlrund: ?*std.Build.Step.Compile = null,
    libcamlruni: ?*std.Build.Step.Compile = null,
    ocamlrun: *std.Build.Step.Compile,
    ocamlrund: ?*std.Build.Step.Compile = null,
    ocamlruni: ?*std.Build.Step.Compile = null,
    libasmrun: ?*std.Build.Step.Compile = null,
    libasmrun_pic: ?*std.Build.Step.Compile = null,
    libasmrun_shared: ?*std.Build.Step.Compile = null,
    libasmrund: ?*std.Build.Step.Compile = null,
    libasmruni: ?*std.Build.Step.Compile = null,
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
    /// Also build debug (`d`) and instrumented (`i`) runtime variants.
    variants: bool = false,
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
    zstd_lib.root_module.strip = true;

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

    // 5. Bytecode runtime libraries and executables
    const buildCamlrunLib = struct {
        fn f(rt_self: Artifacts, s: Source, name: []const u8, linkage: std.builtin.LinkMode, pic: ?bool, files: []const []const u8, flags: []const []const u8, opt: std.builtin.OptimizeMode) *std.Build.Step.Compile {
            const lib = s.b.addLibrary(.{
                .linkage = linkage,
                .name = name,
                .root_module = cModule(s.b, rt_self.platform, opt, .{ .pic = pic }),
            });
            rt_self.addIncludes(s, lib.root_module);
            lib.root_module.linkLibrary(rt_self.zstd_lib);
            lib.root_module.addCSourceFiles(.{ .root = s.path(""), .files = files, .flags = flags });
            if (linkage == .dynamic) {
                lib.linker_allow_shlib_undefined = true;
                rt_self.platform.c.linkLibs(lib.root_module);
            }
            return lib;
        }
    }.f;
    const buildOcamlrunExe = struct {
        fn f(rt_self: Artifacts, s: Source, name: []const u8, prims_c: std.Build.LazyPath, lib: *std.Build.Step.Compile, flags: []const []const u8, opt: std.builtin.OptimizeMode) *std.Build.Step.Compile {
            const exe = s.b.addExecutable(.{
                .name = name,
                // Static musl cannot dlopen bytecode stub libraries.
                .linkage = if (rt_self.platform.resolved.result.abi.isMusl()) .dynamic else null,
                .root_module = cModule(s.b, rt_self.platform, opt, .{}),
            });
            rt_self.addIncludes(s, exe.root_module);
            exe.root_module.addCSourceFile(.{ .file = prims_c, .flags = flags });
            exe.root_module.linkLibrary(lib);
            exe.root_module.linkLibrary(rt_self.zstd_lib);
            rt_self.platform.c.linkLibs(exe.root_module);
            if (rt_self.platform.is_elf) exe.rdynamic = true;
            if (rt_self.platform.is_windows) exe.mingw_unicode_entry_point = true;
            return exe;
        }
    }.f;

    const prims_c = gen.prims_c.lazyPath();
    self.libcamlrun = buildCamlrunLib(self, src, "camlrun", .static, null, bytecode_c, cflags, options.optimize);
    self.ocamlrun = buildOcamlrunExe(self, src, "ocamlrun", prims_c, self.libcamlrun, cflags, options.optimize);
    if (!p.is_windows) {
        self.libcamlrun_pic = buildCamlrunLib(self, src, "camlrun_pic", .static, true, bytecode_c, cflags, options.optimize);
        self.libcamlrun_shared = buildCamlrunLib(self, src, "camlrun_shared", .dynamic, true, bytecode_c, cflags, options.optimize);
    }
    if (options.variants) {
        const d_flags = ocamlcConcat(b, cflags, &.{"-DDEBUG"});
        const i_flags = ocamlcConcat(b, cflags, &.{"-DCAML_INSTR"});
        const d_files = ocamlcConcat(b, bytecode_c, &.{"runtime/instrtrace.c"});
        self.libcamlrund = buildCamlrunLib(self, src, "camlrund", .static, null, d_files, d_flags, options.optimize);
        self.ocamlrund = buildOcamlrunExe(self, src, "ocamlrund", prims_c, self.libcamlrund.?, d_flags, options.optimize);
        self.libcamlruni = buildCamlrunLib(self, src, "camlruni", .static, null, bytecode_c, i_flags, options.optimize);
        self.ocamlruni = buildOcamlrunExe(self, src, "ocamlruni", prims_c, self.libcamlruni.?, i_flags, options.optimize);
    }

    // 6. Native runtime libraries (targets with a native-code backend)
    if (p.runtimeAsmFile()) |asm_file| {
        const native_files = runtimeSources(
            b,
            &.{ rt.common_c_sources, os_c_sources, rt.native_only_c_sources },
            if (std.mem.endsWith(u8, asm_file, ".S")) b.fmt("runtime/{s}", .{asm_file}) else null,
        );
        const nat_flags = ocamlcConcat(b, cflags, p.nativeDefines(b));
        const buildAsmrunLib = struct {
            fn f(rt_self: Artifacts, s: Source, name: []const u8, linkage: std.builtin.LinkMode, pic: ?bool, files: []const []const u8, flags: []const []const u8, opt: std.builtin.OptimizeMode) *std.Build.Step.Compile {
                const lib = s.b.addLibrary(.{
                    .linkage = linkage,
                    .name = name,
                    .root_module = cModule(s.b, rt_self.platform, opt, .{ .pic = pic }),
                });
                rt_self.addIncludes(s, lib.root_module);
                lib.root_module.addCSourceFiles(.{ .root = s.path(""), .files = files, .flags = flags });
                if (linkage == .dynamic) {
                    lib.linker_allow_shlib_undefined = true;
                    rt_self.platform.c.linkLibs(lib.root_module);
                }
                return lib;
            }
        }.f;
        self.libasmrun = buildAsmrunLib(self, src, "asmrun", .static, null, native_files, nat_flags, options.optimize);
        if (!p.is_windows) {
            self.libasmrun_pic = buildAsmrunLib(self, src, "asmrun_pic", .static, true, native_files, nat_flags, options.optimize);
            self.libasmrun_shared = buildAsmrunLib(self, src, "asmrun_shared", .dynamic, true, native_files, nat_flags, options.optimize);
        }
        if (options.variants) {
            self.libasmrund = buildAsmrunLib(self, src, "asmrund", .static, null, native_files, ocamlcConcat(b, nat_flags, &.{"-DDEBUG"}), options.optimize);
            self.libasmruni = buildAsmrunLib(self, src, "asmruni", .static, null, native_files, ocamlcConcat(b, nat_flags, &.{"-DCAML_INSTR"}), options.optimize);
        }
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
        // Cached CRT/compiler-rt objects can contain absolute Zig-install paths.
        // Keep runtime assertions/variants, but omit C DWARF from shipped files.
        .strip = opts.strip orelse true,
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
