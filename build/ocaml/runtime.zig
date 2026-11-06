//! The C runtime: `ocamlrun`, `libcamlrun`, `libasmrun`, `ocamlyacc`, plus the
//! generated headers / primitive tables everything else is built against.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const driver = @import("driver.zig");
const configure = @import("configure.zig");
const Tools = @import("tools.zig");
const flexdll = @import("flexdll.zig");

pub const Common = struct {
    opnames_h: std.Build.LazyPath,
    jumptbl_h: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    prims_c: std.Build.LazyPath,
    opcodes_ml: std.Build.LazyPath,
    opcodes_mli: std.Build.LazyPath,
    opnames_ml: std.Build.LazyPath,
    version_h: std.Build.LazyPath,
    exec_h: std.Build.LazyPath,
};

pub fn buildCommon(src: *const Source) Common {
    const b = src.b;
    const rt = src.manifest.runtime;

    const bytecode_c = runtimeSources(b, &.{ rt.common_c_sources, rt.unix_c_sources, rt.win32_c_sources, rt.bytecode_only_c_sources }, null);
    const c_inputs = b.allocator.alloc(Tools.InputFile, bytecode_c.len) catch @panic("OOM");
    for (c_inputs, bytecode_c) |*in, rel| in.* = .of(src.path(rel));

    const gen, _ = Tools.run(b, .gen_runtime, .{
        .instruct_h = .of(src.path("runtime/caml/instruct.h")),
        .opnames_h = .of("opnames.h"),
        .jumptbl_h = .of("jumptbl.h"),
        .primitives = .of("primitives"),
        .prims_c = .of("prims.c"),
        .c_files = c_inputs,
        .opcodes_ml = .of("opcodes.ml"),
        .opcodes_mli = .of("opcodes.mli"),
        .opnames_ml = .of("opnames.ml"),
    });

    const config = b.addWriteFiles();
    const version_h = config.add("caml/version.h", configure.versionH(src));
    const exec_h = config.add("caml/exec.h", configure.execH(src));

    return .{
        .opnames_h = gen.opnames_h.lazyPath(),
        .jumptbl_h = gen.jumptbl_h.lazyPath(),
        .primitives = gen.primitives.lazyPath(),
        .prims_c = gen.prims_c.lazyPath(),
        .opcodes_ml = gen.opcodes_ml.lazyPath(),
        .opcodes_mli = gen.opcodes_mli.lazyPath(),
        .opnames_ml = gen.opnames_ml.lazyPath(),
        .version_h = version_h,
        .exec_h = exec_h,
    };
}

pub const Options = struct {
    platform: Platform,
    /// Also build debug (`d`) and instrumented (`i`) runtime variants.
    variants: bool = false,
    /// Windows: without it the runtime has no dynamic linking support.
    flexlink_exe: ?std.Build.LazyPath = null,
    /// With `flexlink_exe`: where the build machine's `zcaml-cc-<platform>` is.
    cc_dir: ?std.Build.LazyPath = null,
};

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
    ocamlrun: std.Build.LazyPath,
    ocamlrund: ?std.Build.LazyPath = null,
    ocamlruni: ?std.Build.LazyPath = null,
    /// `null` when linked with `flexlink`.
    ocamlrun_step: ?*std.Build.Step.Compile = null,
    libasmrun: ?*std.Build.Step.Compile = null,
    libasmrun_pic: ?*std.Build.Step.Compile = null,
    libasmrun_shared: ?*std.Build.Step.Compile = null,
    libasmrund: ?*std.Build.Step.Compile = null,
    libasmruni: ?*std.Build.Step.Compile = null,
    libcomprmarsh: *std.Build.Step.Compile,
    zstd_lib: *std.Build.Step.Compile,
    zstd_license: std.Build.LazyPath,
    /// `libasmrun.a`, `libcomprmarsh.a` and `libzstd.a`, for linking native programs.
    native_runtime_dir: ?std.Build.LazyPath = null,
    flexlink: ?driver.Flexlink = null,

    /// Include paths for C code built against the runtime (runtime, stubs, ...).
    pub fn addIncludes(self: Artifacts, src: *const Source, mod: *std.Build.Module) void {
        mod.addIncludePath(self.headers_dir);
        mod.addIncludePath(self.headers_dir.path(src.b, "caml"));
        mod.addIncludePath(src.path("runtime"));
        if (self.platform.is_windows) mod.addIncludePath(src.deps.flexdll.path(""));
    }
};

pub fn build(src: *const Source, common: Common, options: Options) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const p = options.platform;
    const rt = m.runtime;
    const os_c_sources = if (p.is_windows) rt.win32_c_sources else rt.unix_c_sources;

    const zstd_dep = src.deps.zstd(b, .{ .target = p.resolved, .optimize = .ReleaseFast, .pie = true });
    const zstd_lib = zstd_dep.artifact("zstd");
    // OCaml links this archive through `zig cc`, not Zig's build linker.
    // Match the runtime's C flags and avoid a dependency on Zig's UBSan runtime.
    zstd_lib.root_module.sanitize_c = .off;
    zstd_lib.root_module.strip = true;

    const bytecode_c = runtimeSources(b, &.{ rt.common_c_sources, os_c_sources, rt.bytecode_only_c_sources }, null);

    const headers = b.addWriteFiles();
    _ = headers.add("caml/m.h", configure.machineH(src, p));
    _ = headers.add("caml/s.h", configure.systemH(src, p));
    _ = headers.addCopyFile(common.version_h, "caml/version.h");
    _ = headers.addCopyFile(common.exec_h, "caml/exec.h");
    _ = headers.add("build_config.h", configure.buildConfigH(src, p));
    _ = headers.addCopyFile(common.opnames_h, "caml/opnames.h");
    _ = headers.addCopyFile(common.jumptbl_h, "caml/jumptbl.h");

    var self: Artifacts = .{
        .platform = p,
        .headers_dir = headers.getDirectory(),
        .primitives = common.primitives,
        .ocamlyacc = undefined,
        .libcamlrun = undefined,
        .ocamlrun = undefined,
        .libasmrun = null,
        .libcomprmarsh = undefined,
        .zstd_lib = zstd_lib,
        .zstd_license = zstd_dep.path("LICENSE-ZSTD"),
    };

    const runtime_cflags = p.c.flags(b, &.{
        "-fno-common",
        "-DIN_CAML_RUNTIME",
        "-DCAMLDLLIMPORT=",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
    });
    const cflags = if (p.is_elf)
        driver.concat(b, runtime_cflags, &.{"-ffunction-sections"})
    else if (p.is_windows and options.flexlink_exe == null)
        driver.concat(b, runtime_cflags, &.{"-DBUILDING_LIBCAMLRUNS"})
    else
        runtime_cflags;

    if (p.is_windows) if (options.flexlink_exe) |exe| {
        self.flexlink = .{
            .exe = exe,
            .support_dir = flexdll.supportDir(b, src.deps.flexdll, p),
            .flags = p.flexlinkFlags(b),
            .cc_dir = options.cc_dir orelse @panic("flexlink needs the C compiler"),
        };
    };

    self.ocamlyacc = b.addExecutable(.{
        .name = "ocamlyacc",
        .root_module = p.cModule(b, .{}),
    });
    self.addIncludes(src, self.ocamlyacc.root_module);
    self.ocamlyacc.root_module.addCSourceFiles(.{
        .root = src.path(""),
        .files = driver.concat(b, if (p.is_windows) &.{"yacc/wstr.c"} else &.{}, rt.ocamlyacc_c_sources),
        .flags = p.c.flags(b, &.{ "-DNDEBUG", "-DCAMLDLLIMPORT=" }),
    });
    if (p.is_windows) self.ocamlyacc.mingw_unicode_entry_point = true;

    self.libcamlrun = buildRuntimeLib(self, src, "camlrun", .static, null, bytecode_c, cflags, true);
    const ocamlrun = linkOcamlrun(self, src, "ocamlrun", common.prims_c, self.libcamlrun, cflags);
    self.ocamlrun = ocamlrun.bin;
    self.ocamlrun_step = ocamlrun.step;
    if (!p.is_windows) {
        self.libcamlrun_pic = buildRuntimeLib(self, src, "camlrun_pic", .static, true, bytecode_c, cflags, true);
        self.libcamlrun_shared = buildRuntimeLib(self, src, "camlrun_shared", .dynamic, true, bytecode_c, cflags, true);
    }
    if (options.variants) {
        const d_flags = driver.concat(b, cflags, &.{"-DDEBUG"});
        const i_flags = driver.concat(b, cflags, &.{"-DCAML_INSTR"});
        const d_files = driver.concat(b, bytecode_c, &.{"runtime/instrtrace.c"});
        self.libcamlrund = buildRuntimeLib(self, src, "camlrund", .static, null, d_files, d_flags, true);
        self.ocamlrund = linkOcamlrun(self, src, "ocamlrund", common.prims_c, self.libcamlrund.?, d_flags).bin;
        self.libcamlruni = buildRuntimeLib(self, src, "camlruni", .static, null, bytecode_c, i_flags, true);
        self.ocamlruni = linkOcamlrun(self, src, "ocamlruni", common.prims_c, self.libcamlruni.?, i_flags).bin;
    }

    if (p.runtimeAsmFile()) |asm_file| {
        const native_files = runtimeSources(
            b,
            &.{ rt.common_c_sources, os_c_sources, rt.native_only_c_sources },
            if (std.mem.endsWith(u8, asm_file, ".S")) b.fmt("runtime/{s}", .{asm_file}) else null,
        );
        const nat_flags = driver.concat(b, cflags, p.nativeDefines(b));
        self.libasmrun = buildRuntimeLib(self, src, "asmrun", .static, null, native_files, nat_flags, false);
        if (!p.is_windows) {
            self.libasmrun_pic = buildRuntimeLib(self, src, "asmrun_pic", .static, true, native_files, nat_flags, false);
            self.libasmrun_shared = buildRuntimeLib(self, src, "asmrun_shared", .dynamic, true, native_files, nat_flags, false);
        }
        if (options.variants) {
            self.libasmrund = buildRuntimeLib(self, src, "asmrund", .static, null, native_files, driver.concat(b, nat_flags, &.{"-DDEBUG"}), false);
            self.libasmruni = buildRuntimeLib(self, src, "asmruni", .static, null, native_files, driver.concat(b, nat_flags, &.{"-DCAML_INSTR"}), false);
        }
    }

    self.libcomprmarsh = b.addLibrary(.{
        .linkage = .static,
        .name = "comprmarsh",
        .root_module = p.cModule(b, .{ .pic = true }),
    });
    self.addIncludes(src, self.libcomprmarsh.root_module);
    self.libcomprmarsh.root_module.linkLibrary(zstd_lib);
    self.libcomprmarsh.root_module.addCSourceFile(.{ .file = src.path("runtime/zstd.c"), .flags = cflags });

    if (self.libasmrun) |asmrun| {
        const runtime_dir = b.addWriteFiles();
        _ = runtime_dir.addCopyFile(asmrun.getEmittedBin(), "libasmrun.a");
        _ = runtime_dir.addCopyFile(self.libcomprmarsh.getEmittedBin(), "libcomprmarsh.a");
        _ = runtime_dir.addCopyFile(self.zstd_lib.getEmittedBin(), "libzstd.a");
        self.native_runtime_dir = runtime_dir.getDirectory();
    }

    return self;
}

fn buildRuntimeLib(
    rt: Artifacts,
    src: *const Source,
    name: []const u8,
    linkage: std.builtin.LinkMode,
    pic: ?bool,
    files: []const []const u8,
    flags: []const []const u8,
    link_zstd: bool,
) *std.Build.Step.Compile {
    const lib = src.b.addLibrary(.{
        .linkage = linkage,
        .name = name,
        .root_module = rt.platform.cModule(src.b, .{ .pic = pic }),
    });
    rt.addIncludes(src, lib.root_module);
    if (link_zstd) lib.root_module.linkLibrary(rt.zstd_lib);
    lib.root_module.addCSourceFiles(.{ .root = src.path(""), .files = files, .flags = flags });
    if (linkage == .dynamic) {
        lib.linker_allow_shlib_undefined = true;
        rt.platform.c.linkLibs(lib.root_module);
    }
    return lib;
}

/// `step` is `null` when linked with `flexlink`.
fn linkOcamlrun(
    rt: Artifacts,
    src: *const Source,
    name: []const u8,
    prims_c: std.Build.LazyPath,
    lib: *std.Build.Step.Compile,
    flags: []const []const u8,
) struct { bin: std.Build.LazyPath, step: ?*std.Build.Step.Compile } {
    const b = src.b;
    const p = rt.platform;
    if (rt.flexlink) |fl| {
        const prims = b.addObject(.{ .name = b.fmt("{s}_prims", .{name}), .root_module = p.cModule(b, .{}) });
        rt.addIncludes(src, prims.root_module);
        prims.root_module.addCSourceFile(.{ .file = prims_c, .flags = flags });

        const run = fl.run(b);
        run.addArgs(&.{ "-exe", "-o" });
        const out = run.addOutputFileArg(b.fmt("{s}.exe", .{name}));
        run.addFileArg(prims.getEmittedBin());
        run.addFileArg(lib.getEmittedBin());
        run.addFileArg(rt.zstd_lib.getEmittedBin());
        for (p.c.libs) |l| run.addArg(b.fmt("-l{s}", .{l}));
        run.addArgs(&.{ "-link", "-municode" });
        return .{ .bin = out, .step = null };
    }

    const exe = b.addExecutable(.{
        .name = name,
        // Static musl cannot dlopen bytecode stub libraries.
        .linkage = if (p.resolved.result.abi.isMusl()) .dynamic else null,
        .root_module = p.cModule(b, .{ .strip = !p.is_macos }),
    });
    rt.addIncludes(src, exe.root_module);
    exe.root_module.addCSourceFile(.{ .file = prims_c, .flags = flags });
    exe.root_module.linkLibrary(lib);
    exe.root_module.linkLibrary(rt.zstd_lib);
    p.c.linkLibs(exe.root_module);
    if (p.is_windows) {
        exe.mingw_unicode_entry_point = true;
    } else {
        exe.rdynamic = true;
        // Keep symbols referenced only by dlopen'd stublibs (`dllunixbyt.so`, ...) exported.
        exe.link_gc_sections = false;
    }
    return .{ .bin = exe.getEmittedBin(), .step = exe };
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
