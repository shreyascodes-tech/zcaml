//! Build OCaml toolchains from source with Zig, memoizing shared build
//! artifacts (runtimes, stdlib, bytecode/native compiler waves, and build-host
//! native emitters) across one or more `(host, target)` pairs.
//!
//! ```zig
//! const src = Ocaml.Versions.source(b, .@"5.5.1", deps) orelse return;
//! var ocaml: Ocaml = .init(src, .{});
//! const toolchain = ocaml.build(host, target);
//! toolchain.addInstall(b.getInstallStep(), "5.5.1/host-x86_64-linux-gnu/target-x86_64-linux-gnu");
//! ```
//!
//! The result is a self-contained, relocatable install tree:
//!
//! ```text
//! bin/        ocamlc ocamlopt ocaml ocamlrun ... (+ ocamlrun-target when cross compiling)
//! lib/ocaml/  stdlib, runtime libs & headers, compiler-libs, otherlibs, stublibs/
//! ```
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const compiler = @import("compiler.zig");
const extras = @import("extras.zig");
const otherlibs = @import("otherlibs.zig");
const flexdll = @import("flexdll.zig");
const driver = @import("driver.zig");
const configure = @import("configure.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const LazyPath = std.Build.LazyPath;
const SMap = std.StringHashMapUnmanaged;

pub const Versions = @import("versions.zig");
pub const Deps = Source.Deps;
pub const Version = Versions.Version;
pub const resolveTarget = Platform.resolveTarget;
pub const MacosSdk = @import("macos_sdk.zig");

const Ocaml = @This();

src: *const Source,
opts: Options,
build_platform: Platform,
rt_common: runtime.Common,
build_rt: runtime.Artifacts,
stdlib_common: stdlib.Common,
comp_shared: compiler.Shared,
ld_conf: LazyPath,

// Memoized artifacts. Keys are platform triplets, `pairKey`s or `codeKey`s.
runtimes: SMap(runtime.Artifacts) = .empty,
launch_infos: SMap(LazyPath) = .empty,
stdlibs: SMap(stdlib.Artifacts) = .empty,
nat_stdlib_dirs: SMap(LazyPath) = .empty,
arch_bytes: std.AutoHashMapUnmanaged(?Platform.Arch, compiler.ArchByte) = .empty,
byte_commons: SMap(compiler.ByteCommon) = .empty,
raw_emitters: SMap(Ocamlopt) = .empty,
otherlibs_map: SMap(otherlibs.Artifacts) = .empty,
native_compilers: SMap(compiler.ArchNative) = .empty,
native_commons: SMap(compiler.NativeCommon) = .empty,
ocamlopt_opts: SMap(LazyPath) = .empty,
ocamllex_opts: SMap(LazyPath) = .empty,
ocamlnats: SMap(LazyPath) = .empty,
// Bytecode is target-independent: compiled once, against the first target's libraries.
debugger_byte: ?extras.DebuggerByte = null,
odoc_byte: ?extras.OcamldocByte = null,
odoc_nats: SMap(extras.OcamldocNative) = .empty,
flexlink_byte: ?flexdll.Byte = null,
flexlink_opts: SMap(LazyPath) = .empty,
cc_wrappers: SMap(*std.Build.Step.Compile) = .empty,
toolchains: SMap(Toolchain) = .empty,

pub const Options = struct {
    ocamldoc: bool = false,
    ocamldebug: bool = false,
    ocamlnat: bool = false,
    bytecode_tools: bool = false,
    runtime_variants: bool = false,
};

pub fn init(src: *const Source, opts: Options) Ocaml {
    const b = src.b;
    const build_platform: Platform = .init(b, resolveTarget(b, "native"));
    const rt_common = runtime.buildCommon(src);
    const build_rt = runtime.build(src, rt_common, .{
        .platform = build_platform,
        .variants = opts.runtime_variants,
    });
    const stdlib_common = stdlib.buildCommon(src, rt_common.primitives, build_rt);
    const comp_shared = compiler.buildShared(src, stdlib_common.base_dir, stdlib_common.build_launch_info_dir, rt_common, build_rt.ocamlrun_step.?, build_rt.ocamlyacc);
    var self: Ocaml = .{
        .src = src,
        .opts = opts,
        .build_platform = build_platform,
        .rt_common = rt_common,
        .build_rt = build_rt,
        .stdlib_common = stdlib_common,
        .comp_shared = comp_shared,
        .ld_conf = b.addWriteFiles().add("ld.conf", "./stublibs\n.\n"),
    };
    // On Windows, `build_rt` has no dynamic linking support (upstream's `ocamlruns`):
    // it runs `flexlink.byte`, which links the toolchain's runtime.
    if (!build_platform.is_windows) self.runtimes.put(b.allocator, build_platform.triplet, build_rt) catch @panic("OOM");
    self.launch_infos.put(b.allocator, build_platform.triplet, stdlib_common.build_launch_info_dir) catch @panic("OOM");
    if (build_platform.hasNativeCompiler()) self.bootstrapEmitter();
    return self;
}

pub fn build(self: *Ocaml, host_resolved: std.Build.ResolvedTarget, target_resolved: std.Build.ResolvedTarget) Toolchain {
    const b = self.src.b;
    const host: Platform = .init(b, host_resolved);
    const target: Platform = .init(b, target_resolved);
    const pair_key = self.pairKey(host, target);
    if (self.toolchains.get(pair_key)) |tc| return tc;

    var comp = compiler.buildBytePrograms(
        self.src,
        self.comp_shared,
        self.getByteCommon(host, target),
        host,
        self.getLaunchInfo(host),
        self.opts.bytecode_tools,
    );

    if (target.hasNativeCompiler()) {
        const target_nat = self.getNativeCompiler(target, target.arch);
        comp.nat_compilerlibs_dir = target_nat.base_libs_dir;
        comp.nat_profiling_dir = target_nat.profiling_dir;
        comp.nat_common = self.getNativeCommon(target, host, target);
    }

    if (host.hasNativeCompiler()) {
        comp.native_programs = compiler.linkNativePrograms(
            self.getArchByte(target.arch),
            self.getNativeCompiler(host, target.arch),
            self.getNativeCommon(host, host, target),
            self.getEmitter(host),
            self.getRuntime(host),
            self.getOcamloptOpt(host, target),
            self.getOcamllexOpt(host),
        );
    }

    const tc: Toolchain = .{
        .b = b,
        .src = self.src,
        .ld_conf = self.ld_conf,
        .makefile_config = b.addWriteFiles().add("Makefile.config", configure.makefileConfig(self.src, host, target)),
        .cc_wrapper = self.getCcWrapper(host, target),
        .host_rt = self.getRuntime(host),
        .target_rt = self.getRuntime(target),
        .stdlib = self.getStdlib(target),
        .compiler = comp,
        .otherlibs = self.getOtherlibs(target),
        .ocamlnat = if (self.opts.ocamlnat and target.hasNativeCompiler()) self.getOcamlnat(target) else null,
        .ocamldebug = if (self.opts.ocamldebug) self.linkDebugger(host, target) else null,
        .ocamldoc = if (self.opts.ocamldoc) self.linkOcamldoc(host, target) else null,
        .flexlink = if (target.is_windows) .{
            .byte = flexdll.linkByte(self.comp_shared.boot, self.getFlexlinkByte(), self.getLaunchInfo(host), compiler.launchFlags(b, host)),
            .opt = if (host.hasNativeCompiler()) self.getFlexlinkOpt(host) else null,
        } else null,
    };
    self.toolchains.put(b.allocator, pair_key, tc) catch @panic("OOM");
    return tc;
}

/// The build's Zig programs, for the build machine: `zig build check`.
pub fn addCheck(b: *std.Build, step: *std.Build.Step) void {
    const native: Platform = .init(b, resolveTarget(b, "native"));
    step.dependOn(&buildCcWrapper(b, native, native).step);
    step.dependOn(&@import("tools.zig").toolsExe(b).step);
    step.dependOn(&driver.withPathExe(b).step);
}

/// The C compiler for `target` running on `host`: see `cc_wrapper.zig`. Installed
/// with the toolchain, and run during the build too, by the compilers (`rawOcamlopt`).
fn getCcWrapper(self: *Ocaml, host: Platform, target: Platform) *std.Build.Step.Compile {
    const key = self.pairKey(host, target);
    if (self.cc_wrappers.get(key)) |exe| return exe;
    const exe = buildCcWrapper(self.src.b, host, target);
    self.cc_wrappers.put(self.src.b.allocator, key, exe) catch @panic("OOM");
    return exe;
}

fn buildCcWrapper(b: *std.Build, host: Platform, target: Platform) *std.Build.Step.Compile {
    const args = configure.ccWrapperArgs(b, target);
    // The Windows command line is built by plain concatenation.
    for (args) |arg| if (std.mem.findAny(u8, arg, " \t\"") != null) std.debug.panic("cc wrapper argument needs quoting: {s}", .{arg});
    const options = b.addOptions();
    options.addOption([]const []const u8, "args", args);
    options.addOption(bool, "macos_sdk", target.is_macos);

    // Small: it runs for every C compilation.
    const is_windows = host.resolved.result.os.tag == .windows;
    const mod = b.createModule(.{
        .root_source_file = b.path("build/ocaml/cc_wrapper.zig"),
        .target = host.resolved,
        .optimize = .ReleaseSmall,
        .strip = true,
        .single_threaded = true,
        .link_libc = !is_windows,
        .error_tracing = false,
        .sanitize_c = .off,
    });
    mod.addOptions("options", options);
    const exe = b.addExecutable(.{ .name = configure.ccWrapperName(b, target), .root_module = mod });
    exe.link_gc_sections = true;
    exe.bundle_ubsan_rt = false;
    // lld-link keeps most of compiler_rt (~36 KiB); the wrapper has its own `memcpy`/`memset`.
    if (is_windows) exe.bundle_compiler_rt = false;
    return exe;
}

pub const Toolchain = struct {
    b: *std.Build,
    src: *const Source,
    ld_conf: LazyPath,
    makefile_config: LazyPath,
    cc_wrapper: *std.Build.Step.Compile,
    host_rt: runtime.Artifacts,
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    compiler: compiler.Artifacts,
    otherlibs: otherlibs.Artifacts,
    ocamlnat: ?LazyPath = null,
    ocamldebug: ?extras.DebuggerArtifacts = null,
    ocamldoc: ?extras.OcamldocArtifacts = null,
    flexlink: ?struct { byte: LazyPath, opt: ?LazyPath } = null,

    /// Install the layout to `<install prefix>/<sub_path>`.
    pub fn addInstall(tc: Toolchain, step: *std.Build.Step, sub_path: []const u8) void {
        tc.layout(.{ .b = tc.b, .sink = .{ .install = .{ .step = step, .sub_path = sub_path } } });
    }

    /// The install layout as a directory, for using the toolchain in the build itself.
    pub fn directory(tc: Toolchain) LazyPath {
        const wf = tc.b.addWriteFiles();
        tc.layout(.{ .b = tc.b, .sink = .{ .write_files = wf } });
        return wf.getDirectory();
    }

    fn layout(tc: Toolchain, l: Install) void {
        const b = tc.b;
        const host_exe = tc.host_rt.platform.exeExt();
        const target = tc.target_rt.platform;
        const target_exe = target.exeExt();
        const bin = "bin";
        const lib = "lib/ocaml";

        // bin/: host runtime and tools (.opt defaults, with .byte always retained)
        l.file(tc.host_rt.ocamlrun, b.fmt("{s}/ocamlrun{s}", .{ bin, host_exe }));
        if (tc.host_rt.ocamlrund) |a| l.file(a, b.fmt("{s}/ocamlrund{s}", .{ bin, host_exe }));
        if (tc.host_rt.ocamlruni) |a| l.file(a, b.fmt("{s}/ocamlruni{s}", .{ bin, host_exe }));
        l.artifact(tc.host_rt.ocamlyacc, bin);
        l.artifact(tc.cc_wrapper, bin);
        if (!tc.host_rt.platform.eql(target)) {
            l.file(tc.target_rt.ocamlrun, b.fmt("{s}/ocamlrun-target{s}", .{ bin, target_exe }));
            if (tc.target_rt.ocamlrund) |a| l.file(a, b.fmt("{s}/ocamlrund-target{s}", .{ bin, target_exe }));
            if (tc.target_rt.ocamlruni) |a| l.file(a, b.fmt("{s}/ocamlruni-target{s}", .{ bin, target_exe }));
        }
        if (tc.flexlink) |fl| {
            l.file(fl.opt orelse fl.byte, b.fmt("{s}/flexlink{s}", .{ bin, host_exe }));
            if (fl.opt) |exe| l.file(exe, b.fmt("{s}/flexlink.opt{s}", .{ bin, host_exe }));
            l.file(fl.byte, b.fmt("{s}/flexlink.byte{s}", .{ bin, host_exe }));
        }

        const progs = tc.compiler.programs;
        const nat = tc.compiler.native_programs;
        for ([_]struct { []const u8, LazyPath, ?LazyPath }{
            .{ "ocamlc", progs.ocamlc, if (nat) |n| n.ocamlc else null },
            .{ "ocamlopt", progs.ocamlopt, if (nat) |n| n.ocamlopt else null },
            .{ "ocamllex", progs.ocamllex, if (nat) |n| n.ocamllex else null },
            .{ "ocamldep", progs.ocamldep, if (nat) |n| n.ocamldep else null },
            .{ "ocamlobjinfo", progs.ocamlobjinfo, if (nat) |n| n.ocamlobjinfo else null },
        }) |entry| {
            const name, const byte, const native = entry;
            l.file(native orelse byte, b.fmt("{s}/{s}{s}", .{ bin, name, host_exe }));
            if (native) |exe| l.file(exe, b.fmt("{s}/{s}.opt{s}", .{ bin, name, host_exe }));
            l.file(byte, b.fmt("{s}/{s}.byte{s}", .{ bin, name, host_exe }));
        }
        if (tc.ocamlnat) |exe| l.file(exe, b.fmt("{s}/ocamlnat{s}", .{ bin, target_exe }));
        if (tc.ocamldebug) |dbg| {
            l.file(dbg.exe, b.fmt("{s}/ocamldebug{s}", .{ bin, host_exe }));
            l.file(dbg.cmi, lib ++ "/compiler-libs/ocamldebug.cmi");
            l.file(dbg.parser_aux_cmi, lib ++ "/compiler-libs/parser_aux.cmi");
        }
        if (tc.ocamldoc) |odoc| {
            const default_odoc = if (tc.host_rt.platform.eql(target)) odoc.opt orelse odoc.byte else odoc.byte;
            l.file(default_odoc, b.fmt("{s}/ocamldoc{s}", .{ bin, host_exe }));
            if (odoc.opt) |exe| l.file(exe, b.fmt("{s}/ocamldoc.opt{s}", .{ bin, target_exe }));
            l.file(odoc.byte, b.fmt("{s}/ocamldoc.byte{s}", .{ bin, host_exe }));
            l.dir(odoc.lib_dir, lib ++ "/ocamldoc", &.{});
        }
        if (progs.bytecode_tools) |bt| {
            for ([_]struct { []const u8, LazyPath }{
                .{ "cmpbyt", bt.cmpbyt },
                .{ "dumpobj", bt.dumpobj },
                .{ "primreq", bt.primreq },
                .{ "stripdebug", bt.stripdebug },
            }) |entry| {
                l.file(entry[1], b.fmt("{s}/{s}{s}", .{ bin, entry[0], host_exe }));
            }
        }
        for ([_]struct { []const u8, LazyPath }{
            .{ "ocamlcmt", progs.ocamlcmt },
            .{ "ocamlprof", progs.ocamlprof },
            .{ "ocamlcp", progs.ocamlcp },
            .{ "ocamloptp", progs.ocamloptp },
            .{ "ocamlmklib", progs.ocamlmklib },
            .{ "ocamlmktop", progs.ocamlmktop },
            .{ "ocaml", progs.ocaml },
        }) |entry| {
            l.file(entry[1], b.fmt("{s}/{s}{s}", .{ bin, entry[0], host_exe }));
        }
        l.file(progs.expunge, b.fmt("{s}/expunge{s}", .{ lib, host_exe }));

        // lib/ocaml/: target runtime libraries, primitives, ld.conf, C headers
        const rt = tc.target_rt;
        l.artifact(rt.libcamlrun, lib);
        for ([_]?*std.Build.Step.Compile{
            rt.libcamlrun_pic, rt.libcamlrun_shared, rt.libcamlrund,      rt.libcamlruni,
            rt.libasmrun,      rt.libasmrun_pic,     rt.libasmrun_shared, rt.libasmrund,
            rt.libasmruni,
        }) |opt_lib| if (opt_lib) |a| l.artifact(a, lib);
        l.artifact(rt.libcomprmarsh, lib);
        l.artifact(rt.zstd_lib, lib);
        l.file(rt.primitives, lib ++ "/primitives");
        l.file(tc.ld_conf, lib ++ "/ld.conf");
        l.file(tc.makefile_config, lib ++ "/Makefile.config");
        l.dir(tc.src.path("runtime/caml"), lib ++ "/caml", &.{ ".in", "dune" });
        l.dir(rt.headers_dir.path(b, "caml"), lib ++ "/caml", &.{});
        if (rt.flexlink) |fl| l.dir(fl.support_dir, lib ++ "/flexdll", &.{});

        // Licenses of the code in the shipped binaries.
        l.file(tc.src.path("LICENSE"), "share/doc/ocaml/LICENSE");
        l.file(rt.zstd_license, "share/doc/zstd/LICENSE");
        if (tc.flexlink != null) l.file(tc.src.deps.flexdll.path("LICENSE"), "share/doc/flexdll/LICENSE");

        // stdlib (flat in lib/ocaml/, as upstream)
        l.dir(tc.stdlib.dir, lib, &.{});
        l.file(tc.stdlib.meta, lib ++ "/stdlib/META");

        // compiler-libs, profiling
        l.dir(tc.compiler.base_compilerlibs_dir, lib ++ "/compiler-libs", &.{});
        l.file(tc.compiler.ocamlcommon_cma, lib ++ "/compiler-libs/ocamlcommon.cma");
        if (tc.compiler.nat_compilerlibs_dir) |nat_dir| l.dir(nat_dir, lib ++ "/compiler-libs", &.{});
        if (tc.compiler.nat_common) |nc| {
            l.file(nc.config_cmx, lib ++ "/compiler-libs/config.cmx");
            l.file(nc.cmxa, lib ++ "/compiler-libs/ocamlcommon.cmxa");
            l.file(nc.lib, lib ++ "/compiler-libs/ocamlcommon.a");
        }
        l.dir(tc.compiler.byte_profiling_dir, lib ++ "/profiling", &.{});
        if (tc.compiler.nat_profiling_dir) |np| l.dir(np, lib ++ "/profiling", &.{});

        // otherlibs: lib/ocaml/<lib>/, C stubs in lib/ocaml/ and lib/ocaml/stublibs/
        for (tc.otherlibs.libs) |ol| {
            l.dir(ol.dir, b.fmt("{s}/{s}", .{ lib, ol.name }), &.{});
            const stubs = ol.stubs orelse continue;
            l.artifact(stubs.static_byt, lib);
            l.artifact(stubs.static_nat, lib);
            if (stubs.shared_byt) |dll| l.file(dll, b.fmt("{s}/stublibs/{s}", .{ lib, stubs.dllName(target) }));
        }
        for (tc.otherlibs.headers) |h| l.file(h.source, b.fmt("{s}/caml/{s}", .{ lib, h.dest_name }));
    }
};

/// Native code for every target is emitted by an `ocamlopt.opt` running on the build
/// platform. That is compiled by the bytecode `ocamlopt.byte`, registered as the build
/// platform's emitter until then (so the build platform's native stdlib and
/// compiler-libs are compiled by it too).
fn bootstrapEmitter(self: *Ocaml) void {
    const gpa = self.src.b.allocator;
    const bp = self.build_platform;
    const byte_opt = self.rawOcamlopt(self.comp_shared.build_ocamlrun, self.getByteCommon(bp, bp).ocamlopt_byte, bp);
    self.raw_emitters.put(gpa, bp.triplet, byte_opt) catch @panic("OOM");
    const native_opt = self.rawOcamlopt(null, self.getOcamloptOpt(bp, bp), bp);
    self.raw_emitters.put(gpa, bp.triplet, native_opt) catch @panic("OOM");
}

fn getRuntime(self: *Ocaml, p: Platform) runtime.Artifacts {
    if (self.runtimes.get(p.triplet)) |rt| return rt;
    const rt = runtime.build(self.src, self.rt_common, .{
        .platform = p,
        .variants = self.opts.runtime_variants,
        .flexlink_exe = if (p.is_windows) self.buildPlatformFlexlink() else null,
        .cc_dir = if (p.is_windows) self.getCcWrapper(self.build_platform, p).getEmittedBinDirectory() else null,
    });
    self.runtimes.put(self.src.b.allocator, p.triplet, rt) catch @panic("OOM");
    return rt;
}

fn getLaunchInfo(self: *Ocaml, p: Platform) LazyPath {
    if (self.launch_infos.get(p.triplet)) |li| return li;
    const li = stdlib.buildLaunchInfoDir(self.src, self.getRuntime(p));
    self.launch_infos.put(self.src.b.allocator, p.triplet, li) catch @panic("OOM");
    return li;
}

fn getByteCommon(self: *Ocaml, host: Platform, target: Platform) compiler.ByteCommon {
    const key = self.pairKey(host, target);
    if (self.byte_commons.get(key)) |bc| return bc;
    const bc = compiler.buildByteCommon(self.src, self.comp_shared, self.getArchByte(target.arch), host, target, self.getLaunchInfo(host));
    self.byte_commons.put(self.src.b.allocator, key, bc) catch @panic("OOM");
    return bc;
}

fn getArchByte(self: *Ocaml, arch: ?Platform.Arch) compiler.ArchByte {
    if (self.arch_bytes.get(arch)) |ab| return ab;
    const ab = compiler.buildArchByte(self.src, self.comp_shared, arch);
    self.arch_bytes.put(self.src.b.allocator, arch, ab) catch @panic("OOM");
    return ab;
}

fn getStdlib(self: *Ocaml, target: Platform) stdlib.Artifacts {
    if (self.stdlibs.get(target.triplet)) |s| return s;
    const nat_dir: ?LazyPath = if (target.hasNativeCompiler()) self.getNativeStdlibDir(target) else null;
    const s = stdlib.buildForTarget(self.src, self.stdlib_common, self.getLaunchInfo(target), nat_dir);
    self.stdlibs.put(self.src.b.allocator, target.triplet, s) catch @panic("OOM");
    return s;
}

fn getNativeStdlibDir(self: *Ocaml, target: Platform) LazyPath {
    const key = self.codeKey(target);
    if (self.nat_stdlib_dirs.get(key)) |d| return d;
    const d = stdlib.buildNativeDir(self.src, self.stdlib_common, self.getRawEmitter(target), target);
    self.nat_stdlib_dirs.put(self.src.b.allocator, key, d) catch @panic("OOM");
    return d;
}

/// `ocamlopt` compiling for `target`, with no stdlib (see `getEmitter`).
fn getRawEmitter(self: *Ocaml, target: Platform) Ocamlopt {
    if (self.raw_emitters.get(target.triplet)) |opt| return opt;
    const bp = self.build_platform;
    const opt = if (bp.hasNativeCompiler())
        self.rawOcamlopt(null, self.getOcamloptOpt(bp, target), target)
    else
        self.rawOcamlopt(self.comp_shared.build_ocamlrun, self.getByteCommon(bp, target).ocamlopt_byte, target);
    self.raw_emitters.put(self.src.b.allocator, target.triplet, opt) catch @panic("OOM");
    return opt;
}

fn rawOcamlopt(self: *Ocaml, ocamlrun: ?*std.Build.Step.Compile, exe: LazyPath, target: Platform) Ocamlopt {
    return .{
        .b = self.src.b,
        .ocamlrun = ocamlrun,
        .exe = exe,
        .cc_dir = self.getCcWrapper(self.build_platform, target).getEmittedBinDirectory(),
        .stdlib_dir = null,
        .flexlink = if (target.is_windows) self.getRuntime(target).flexlink.? else null,
        .prefix_map = self.src.prefixMap(),
        .cwd = self.src.path(""),
    };
}

/// `ocamlopt` compiling for `target` against its stdlib.
fn getEmitter(self: *Ocaml, target: Platform) Ocamlopt {
    var opt = self.getRawEmitter(target);
    opt.stdlib_dir = self.getStdlib(target).dir;
    return opt;
}

/// The bytecode `ocamlc` running on `host`, compiling for `target` against its stdlib.
fn ocamlcFor(self: *Ocaml, host: Platform, target: Platform) Ocamlc {
    return .{
        .b = self.src.b,
        .ocamlrun = self.comp_shared.build_ocamlrun,
        .exe = self.getByteCommon(host, target).ocamlc_byte,
        .stdlib_dir = self.getStdlib(target).dir,
        .primitives = null,
        .prefix_map = self.src.prefixMap(),
        .cwd = self.src.path(""),
    };
}

fn getOtherlibs(self: *Ocaml, target: Platform) otherlibs.Artifacts {
    if (self.otherlibs_map.get(target.triplet)) |libs| return libs;
    const libs = otherlibs.build(self.src, .{
        .target_rt = self.getRuntime(target),
        .stdlib = self.getStdlib(target),
        .ocamlc = self.ocamlcFor(target, target),
        .ocamlopt = if (target.hasNativeCompiler()) self.getEmitter(target) else undefined,
    });
    self.otherlibs_map.put(self.src.b.allocator, target.triplet, libs) catch @panic("OOM");
    return libs;
}

/// The compiler-libs compiled to native `code`, for a compiler targeting `target_arch`.
fn getNativeCompiler(self: *Ocaml, code: Platform, target_arch: ?Platform.Arch) compiler.ArchNative {
    const key = self.src.b.fmt("{s}->{s}", .{ self.codeKey(code), if (target_arch) |a| @tagName(a) else "none" });
    if (self.native_compilers.get(key)) |an| return an;

    const is_same_arch = target_arch != null and code.arch != null and target_arch.? == code.arch.?;
    const dynlink_dir: ?LazyPath = if (is_same_arch) self.getOtherlibs(code).dynlink_dir else null;
    const frontend: ?compiler.ArchNative = if (is_same_arch) null else self.getNativeCompiler(code, code.arch);

    const an = compiler.buildArchNative(
        self.src,
        self.comp_shared,
        self.getArchByte(target_arch),
        self.getEmitter(code),
        dynlink_dir,
        frontend,
    );
    self.native_compilers.put(self.src.b.allocator, key, an) catch @panic("OOM");
    return an;
}

fn getNativeCommon(self: *Ocaml, code: Platform, host: Platform, target: Platform) compiler.NativeCommon {
    const key = self.src.b.fmt("{s}:{s}", .{ self.codeKey(code), self.pairKey(host, target) });
    if (self.native_commons.get(key)) |nc| return nc;
    const nc = compiler.buildNativeCommon(
        self.src,
        self.getArchByte(target.arch),
        self.getNativeCompiler(code, target.arch),
        self.getByteCommon(host, target).config_main_ml,
        self.getEmitter(code),
    );
    self.native_commons.put(self.src.b.allocator, key, nc) catch @panic("OOM");
    return nc;
}

/// `ocamlopt.opt` running on `host`, compiling for `target`.
fn getOcamloptOpt(self: *Ocaml, host: Platform, target: Platform) LazyPath {
    const key = self.pairKey(host, target);
    if (self.ocamlopt_opts.get(key)) |p| return p;
    const p = compiler.linkOcamloptOpt(
        self.getArchByte(target.arch),
        self.getNativeCompiler(host, target.arch),
        self.getNativeCommon(host, host, target),
        self.getEmitter(host),
        self.getRuntime(host),
    );
    self.ocamlopt_opts.put(self.src.b.allocator, key, p) catch @panic("OOM");
    return p;
}

fn getOcamllexOpt(self: *Ocaml, host: Platform) LazyPath {
    if (self.ocamllex_opts.get(host.triplet)) |p| return p;
    const arch_nat = self.getNativeCompiler(host, host.arch);
    const p = compiler.linkOcamllexOpt(
        self.src,
        self.getArchByte(host.arch),
        arch_nat.lex_compiled.?,
        self.getEmitter(host),
        self.getRuntime(host),
    );
    self.ocamllex_opts.put(self.src.b.allocator, host.triplet, p) catch @panic("OOM");
    return p;
}

fn getOcamlnat(self: *Ocaml, target: Platform) LazyPath {
    if (self.ocamlnats.get(target.triplet)) |p| return p;
    const p = extras.linkOcamlnat(
        self.getArchByte(target.arch),
        self.getNativeCompiler(target, target.arch),
        self.getNativeCommon(target, target, target),
        self.getEmitter(target),
        self.getRuntime(target),
        self.getOtherlibs(target).dynlink_dir,
    );
    self.ocamlnats.put(self.src.b.allocator, target.triplet, p) catch @panic("OOM");
    return p;
}

fn linkDebugger(self: *Ocaml, host: Platform, target: Platform) extras.DebuggerArtifacts {
    return extras.linkDebugger(
        self.src,
        self.getDebuggerByte(target),
        self.ocamlcFor(host, target),
        self.getArchByte(target.arch),
        self.getByteCommon(host, target),
        self.getOtherlibs(target),
        host,
        self.getLaunchInfo(host),
    );
}

fn getDebuggerByte(self: *Ocaml, target: Platform) extras.DebuggerByte {
    if (self.debugger_byte) |db| return db;
    const arch_byte = self.getArchByte(target.arch);
    const db = extras.compileDebugger(
        self.src,
        self.ocamlcFor(target, target),
        self.comp_shared.byte_compflags,
        arch_byte.sources,
        arch_byte.compiled.cmis_dir,
        self.getOtherlibs(target),
    );
    self.debugger_byte = db;
    return db;
}

fn linkOcamldoc(self: *Ocaml, host: Platform, target: Platform) extras.OcamldocArtifacts {
    return extras.linkOcamldoc(
        self.src,
        self.getOcamldocByte(target),
        if (target.hasNativeCompiler()) self.getOcamldocNative(target) else null,
        self.ocamlcFor(host, target),
        self.getByteCommon(host, target).ocamlcommon_cma,
        self.getOtherlibs(target),
        target,
        host,
        self.getLaunchInfo(host),
    );
}

fn getOcamldocByte(self: *Ocaml, target: Platform) extras.OcamldocByte {
    if (self.odoc_byte) |ob| return ob;
    const arch_byte = self.getArchByte(target.arch);
    const ob = extras.compileOcamldocByte(
        self.src,
        self.ocamlcFor(target, target),
        self.comp_shared.byte_compflags,
        arch_byte.sources,
        arch_byte.compiled.cmis_dir,
        self.getOtherlibs(target),
    );
    self.odoc_byte = ob;
    return ob;
}

fn getOcamldocNative(self: *Ocaml, target: Platform) extras.OcamldocNative {
    if (self.odoc_nats.get(target.triplet)) |on| return on;
    const on = extras.compileOcamldocNative(
        self.src,
        self.getOcamldocByte(target),
        self.getEmitter(target),
        self.getArchByte(target.arch).compiled.cmis_dir,
        self.getNativeCompiler(target, target.arch),
        self.getNativeCommon(target, target, target),
        self.getOtherlibs(target),
        self.getRuntime(target),
    );
    self.odoc_nats.put(self.src.b.allocator, target.triplet, on) catch @panic("OOM");
    return on;
}

fn getFlexlinkByte(self: *Ocaml) flexdll.Byte {
    if (self.flexlink_byte) |fb| return fb;
    const fb = flexdll.compileByte(self.comp_shared.boot, self.src.deps.flexdll);
    self.flexlink_byte = fb;
    return fb;
}

fn getFlexlinkOpt(self: *Ocaml, host: Platform) LazyPath {
    if (self.flexlink_opts.get(host.triplet)) |p| return p;
    const p = flexdll.linkNative(self.getEmitter(host), self.getFlexlinkByte(), self.getRuntime(host).native_runtime_dir.?);
    self.flexlink_opts.put(self.src.b.allocator, host.triplet, p) catch @panic("OOM");
    return p;
}

/// The `flexlink` that links Windows runtimes at build time.
fn buildPlatformFlexlink(self: *Ocaml) LazyPath {
    const bp = self.build_platform;
    if (!bp.is_windows and bp.hasNativeCompiler()) return self.getFlexlinkOpt(bp);
    // A native flexlink would have to be linked by flexlink on Windows: use the
    // bytecode one, next to the `ocamlrun` its launcher finds.
    const b = self.src.b;
    const byte = flexdll.linkByte(self.comp_shared.boot, self.getFlexlinkByte(), self.stdlib_common.build_launch_info_dir, compiler.launchFlags(b, bp));
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(self.build_rt.ocamlrun, b.fmt("ocamlrun{s}", .{bp.exeExt()}));
    return wf.addCopyFile(byte, b.fmt("flexlink{s}", .{bp.exeExt()}));
}

fn pairKey(self: *Ocaml, host: Platform, target: Platform) []const u8 {
    return self.src.b.fmt("{s}->{s}", .{ host.triplet, target.triplet });
}

/// Native code depends only on `(arch, system)`.
fn codeKey(self: *Ocaml, p: Platform) []const u8 {
    return self.src.b.fmt("{s}-{s}", .{ p.archName(), p.system });
}

/// Where `Toolchain.layout` puts files: install steps under the install prefix, or a `WriteFile`.
const Install = struct {
    b: *std.Build,
    sink: union(enum) {
        install: struct { step: *std.Build.Step, sub_path: []const u8 },
        write_files: *std.Build.Step.WriteFile,
    },

    fn file(self: Install, src: LazyPath, dest: []const u8) void {
        switch (self.sink) {
            .install => |i| i.step.dependOn(&self.b.addInstallFileWithDir(src, .prefix, self.destPath(dest)).step),
            .write_files => |wf| _ = wf.addCopyFile(src, dest),
        }
    }

    fn dir(self: Install, src: LazyPath, dest: []const u8, exclude_extensions: []const []const u8) void {
        switch (self.sink) {
            .install => |i| i.step.dependOn(&self.b.addInstallDirectory(.{
                .source_dir = src,
                .install_dir = .prefix,
                .install_subdir = self.destPath(dest),
                .exclude_extensions = exclude_extensions,
            }).step),
            .write_files => |wf| _ = wf.addCopyDirectory(src, dest, .{ .exclude_extensions = exclude_extensions }),
        }
    }

    /// Install a compiled artifact, using `lib<name>.a` for static archives (as OCaml expects on mingw).
    fn artifact(self: Install, a: *std.Build.Step.Compile, dest_dir: []const u8) void {
        const name = if (a.kind == .lib and a.linkage == .static)
            self.b.fmt("lib{s}.a", .{a.name})
        else
            a.out_filename;
        self.file(a.getEmittedBin(), self.b.fmt("{s}/{s}", .{ dest_dir, name }));
    }

    fn destPath(self: Install, dest: []const u8) []const u8 {
        const sub_path = self.sink.install.sub_path;
        return if (sub_path.len == 0) dest else self.b.fmt("{s}/{s}", .{ sub_path, dest });
    }
};
