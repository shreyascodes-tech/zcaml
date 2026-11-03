//! Build OCaml toolchains from source with Zig, memoizing shared build
//! artifacts (runtimes, stdlib, bytecode/native compiler waves, and build-host
//! native emitters) across one or more `(host, target)` pairs.
//!
//! ```zig
//! const ocaml_versions: Ocaml.Versions = .init(b);
//! const src = ocaml_versions.source(.@"5.5.1") orelse return;
//! var ocaml: Ocaml = .init(src, .{});
//! const toolchain = ocaml.build(host, target);
//! toolchain.addInstall(b.getInstallStep(), "5.5.1/host-x86_64-linux-gnu/target-x86_64-linux-gnu");
//! ```
//!
//! The result is a self-contained, relocatable install tree (`toolchain.layout`):
//!
//! ```text
//! bin/        ocamlc ocamlopt ocaml ocamlrun ... (+ ocamlrun-target when cross compiling)
//! lib/ocaml/  stdlib, runtime libs & headers, compiler-libs, otherlibs, stublibs/
//! ```
const std = @import("std");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const compiler = @import("compiler.zig");
const extras = @import("extras.zig");
const otherlibs = @import("otherlibs.zig");
const flexdll = @import("flexdll.zig");
const driver = @import("driver.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const LazyPath = std.Build.LazyPath;
const SMap = std.StringHashMapUnmanaged;

pub const Source = @import("source.zig");
pub const Platform = @import("platform.zig");
pub const Versions = @import("versions.zig");
pub const Version = Versions.Version;
pub const resolveTarget = Platform.resolveTarget;

const Ocaml = @This();

src: *const Source,
opts: Options,
build_platform: Platform,
rt_common: runtime.Common,
build_rt: runtime.Artifacts,
stdlib_common: stdlib.Common,
comp_shared: compiler.Shared,
ld_conf: LazyPath,

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
ocamllex_opts: SMap(LazyPath) = .empty,
ocamlnats: SMap(LazyPath) = .empty,
debugger_byte: ?extras.DebuggerByte = null,
odoc_byte: ?extras.OcamldocByte = null,
odoc_nats: SMap(extras.OcamldocNative) = .empty,
flexlink_byte: ?flexdll.Byte = null,
flexlink_opts: SMap(LazyPath) = .empty,
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
    const rt_common = runtime.buildCommon(src.*);
    const build_rt = runtime.build(src.*, rt_common, .{
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
    return self;
}

pub const Toolchain = struct {
    b: *std.Build,
    ocaml_src: Source,
    ld_conf: LazyPath,
    host_rt: runtime.Artifacts,
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    compiler: compiler.Artifacts,
    otherlibs: otherlibs.Artifacts,
    ocamlnat: ?LazyPath = null,
    ocamldebug: ?extras.DebuggerArtifacts = null,
    ocamldoc: ?extras.OcamldocArtifacts = null,
    flexlink: ?struct { byte: LazyPath, opt: ?LazyPath } = null,

    /// Install the layout directly to `<install prefix>/<sub_path>`.
    pub fn addInstall(self: Toolchain, step: *std.Build.Step, sub_path: []const u8) void {
        self.populateLayout(.{ .install = .{
            .b = self.b,
            .step = step,
            .sub_path = sub_path,
        } });
    }

    /// Materialize the install tree as a build-cache `LazyPath` directory.
    pub fn layout(self: Toolchain) LazyPath {
        const wf = self.b.addWriteFiles();
        self.populateLayout(.{ .wf = .{ .b = self.b, .wf = wf } });
        return wf.getDirectory();
    }

    fn populateLayout(tc: Toolchain, l: Layout) void {
        const src = tc.ocaml_src;
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
        for ([_]struct { []const u8, LazyPath }{
            .{ "ocamlc", progs.ocamlc },
            .{ "ocamlopt", progs.ocamlopt },
            .{ "ocamllex", progs.ocamllex },
            .{ "ocamldep", progs.ocamldep },
            .{ "ocamlobjinfo", progs.ocamlobjinfo },
        }) |entry| {
            const native = if (tc.compiler.native_programs) |p| blk: {
                inline for (comptime std.meta.fieldNames(compiler.NativePrograms)) |name| {
                    if (std.mem.eql(u8, name, entry[0])) break :blk @field(p, name);
                }
                unreachable;
            } else null;
            l.file(native orelse entry[1], b.fmt("{s}/{s}{s}", .{ bin, entry[0], host_exe }));
            if (native) |exe| l.file(exe, b.fmt("{s}/{s}.opt{s}", .{ bin, entry[0], host_exe }));
            l.file(entry[1], b.fmt("{s}/{s}.byte{s}", .{ bin, entry[0], host_exe }));
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
        l.artifact(tc.target_rt.libcamlrun, lib);
        if (tc.target_rt.libcamlrun_pic) |a| l.artifact(a, lib);
        if (tc.target_rt.libcamlrun_shared) |a| l.artifact(a, lib);
        if (tc.target_rt.libcamlrund) |a| l.artifact(a, lib);
        if (tc.target_rt.libcamlruni) |a| l.artifact(a, lib);
        if (tc.target_rt.libasmrun) |a| l.artifact(a, lib);
        if (tc.target_rt.libasmrun_pic) |a| l.artifact(a, lib);
        if (tc.target_rt.libasmrun_shared) |a| l.artifact(a, lib);
        if (tc.target_rt.libasmrund) |a| l.artifact(a, lib);
        if (tc.target_rt.libasmruni) |a| l.artifact(a, lib);
        l.artifact(tc.target_rt.libcomprmarsh, lib);
        l.artifact(tc.target_rt.zstd_lib, lib);
        l.file(tc.target_rt.primitives, lib ++ "/primitives");
        l.file(tc.ld_conf, lib ++ "/ld.conf");
        l.dir(src.path("runtime/caml"), lib ++ "/caml", &.{ ".in", "dune" });
        l.dir(tc.target_rt.headers_dir.path(b, "caml"), lib ++ "/caml", &.{});
        if (tc.target_rt.flexlink) |fl| l.dir(fl.support_dir, lib ++ "/flexdll", &.{});

        // stdlib (flat in lib/ocaml/, as upstream)
        l.dir(tc.stdlib.dir, lib, &.{});
        l.file(tc.stdlib.meta, lib ++ "/stdlib/META");

        // compiler-libs, profiling
        l.dir(tc.compiler.base_compilerlibs_dir, lib ++ "/compiler-libs", &.{});
        l.file(tc.compiler.ocamlcommon_cma, lib ++ "/compiler-libs/ocamlcommon.cma");
        if (tc.compiler.nat_compilerlibs_dir) |nat_dir| {
            l.dir(nat_dir, lib ++ "/compiler-libs", &.{});
        }
        if (tc.compiler.nat_common) |nc| {
            l.file(nc.config_cmx, lib ++ "/compiler-libs/config.cmx");
            l.file(nc.cmxa, lib ++ "/compiler-libs/ocamlcommon.cmxa");
            l.file(nc.lib, lib ++ "/compiler-libs/ocamlcommon.a");
        }
        l.dir(tc.compiler.byte_profiling_dir, lib ++ "/profiling", &.{});
        if (tc.compiler.nat_profiling_dir) |np| {
            l.dir(np, lib ++ "/profiling", &.{});
        }

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

pub fn build(self: *Ocaml, host_resolved: std.Build.ResolvedTarget, target_resolved: std.Build.ResolvedTarget) Toolchain {
    const b = self.src.b;
    const host: Platform = .init(b, host_resolved);
    const target: Platform = .init(b, target_resolved);
    const pair_key = b.fmt("{s}->{s}", .{ host.triplet, target.triplet });
    if (self.toolchains.get(pair_key)) |tc| return tc;

    const host_rt = self.getRuntime(host);
    const target_rt = self.getRuntime(target);
    const target_stdlib = self.getStdlib(target);
    const target_arch_byte = self.getArchByte(target.arch);
    const byte_common = self.getByteCommon(host, target);
    const libs = self.getOtherlibs(target);

    var comp = compiler.buildBytePrograms(
        self.src,
        self.comp_shared,
        byte_common,
        host,
        self.launchInfo(host),
        self.opts.bytecode_tools,
    );

    if (target.hasNativeCompiler()) {
        const target_nat = self.getNativeCompiler(target, target.arch);
        comp.nat_compilerlibs_dir = target_nat.base_libs_dir;
        comp.nat_profiling_dir = target_nat.profiling_dir;
        comp.nat_common = self.getNativeCommon(target, host, target);
    }

    if (host.hasNativeCompiler()) {
        const arch_nat = self.getNativeCompiler(host, target.arch);
        const nat_common = self.getNativeCommon(host, host, target);
        const ocamllex_opt = self.getOcamllexOpt(host);
        comp.native_programs = compiler.linkNativePrograms(
            b,
            target_arch_byte,
            arch_nat,
            nat_common,
            self.getEmitter(host),
            host_rt,
            ocamllex_opt,
        );
    }

    const ocamlnat = if (self.opts.ocamlnat and target.hasNativeCompiler())
        self.getOcamlnat(target)
    else
        null;
    const ocamldebug = if (self.opts.ocamldebug)
        self.getDebugger(host, target)
    else
        null;
    const ocamldoc = if (self.opts.ocamldoc)
        self.getOcamldoc(host, target)
    else
        null;

    const flexlink: @FieldType(Toolchain, "flexlink") = if (target.is_windows) .{
        .byte = flexdll.linkByte(self.comp_shared.boot, self.getFlexlinkByte(), self.launchInfo(host), compiler.launchFlags(b, host)),
        .opt = if (host.hasNativeCompiler()) self.getFlexlinkOpt(host) else null,
    } else null;

    const tc: Toolchain = .{
        .b = b,
        .flexlink = flexlink,
        .ocaml_src = self.src.*,
        .ld_conf = self.ld_conf,
        .host_rt = host_rt,
        .target_rt = target_rt,
        .stdlib = target_stdlib,
        .compiler = comp,
        .otherlibs = libs,
        .ocamlnat = ocamlnat,
        .ocamldebug = ocamldebug,
        .ocamldoc = ocamldoc,
    };
    self.toolchains.put(b.allocator, pair_key, tc) catch @panic("OOM");
    return tc;
}

fn getRuntime(self: *Ocaml, p: Platform) runtime.Artifacts {
    if (self.runtimes.get(p.triplet)) |rt| return rt;
    const rt = runtime.build(self.src.*, self.rt_common, .{
        .platform = p,
        .variants = self.opts.runtime_variants,
        .flexlink_exe = if (p.is_windows) self.buildFlexlink() else null,
    });
    self.runtimes.put(self.src.b.allocator, p.triplet, rt) catch @panic("OOM");
    return rt;
}

fn launchInfo(self: *Ocaml, p: Platform) LazyPath {
    if (self.launch_infos.get(p.triplet)) |li| return li;
    const li = stdlib.buildLaunchInfoDir(self.src.*, self.getRuntime(p));
    self.launch_infos.put(self.src.b.allocator, p.triplet, li) catch @panic("OOM");
    return li;
}

fn getStdlib(self: *Ocaml, target: Platform) stdlib.Artifacts {
    if (self.stdlibs.get(target.triplet)) |s| return s;
    const b = self.src.b;
    const li = self.launchInfo(target);
    if (!target.hasNativeCompiler()) {
        const byte_stdlib = stdlib.buildForTarget(self.src, self.stdlib_common, target.arch, li, null);
        self.stdlibs.put(b.allocator, target.triplet, byte_stdlib) catch @panic("OOM");
        return byte_stdlib;
    }
    const raw_emitter = self.getRawEmitter(target);
    if (self.stdlibs.get(target.triplet)) |s| return s;

    const key = self.codeKey(target);
    const nat_dir = self.nat_stdlib_dirs.get(key) orelse blk: {
        const d = stdlib.buildNativeDir(self.src, self.stdlib_common, raw_emitter, target);
        self.nat_stdlib_dirs.put(b.allocator, key, d) catch @panic("OOM");
        break :blk d;
    };
    const s = stdlib.buildForTarget(self.src, self.stdlib_common, target.arch, li, nat_dir);
    self.stdlibs.put(b.allocator, target.triplet, s) catch @panic("OOM");
    return s;
}

fn getRawEmitter(self: *Ocaml, target: Platform) Ocamlopt {
    if (self.raw_emitters.get(target.triplet)) |opt| return opt;
    const b = self.src.b;
    if (!self.build_platform.hasNativeCompiler()) {
        const opt = self.rawOcamlopt(self.comp_shared.build_ocamlrun, self.getByteCommon(self.build_platform, target).ocamlopt_byte, target);
        self.raw_emitters.put(b.allocator, target.triplet, opt) catch @panic("OOM");
        return opt;
    }

    if (target.eql(self.build_platform)) {
        const boot_opt = self.rawOcamlopt(self.comp_shared.build_ocamlrun, self.getByteCommon(self.build_platform, self.build_platform).ocamlopt_byte, self.build_platform);
        // Seed the bootstrap bytecode emitter to break the cycle when getNativeCommon compiles the native stdlib for build_platform.
        self.raw_emitters.put(b.allocator, self.build_platform.triplet, boot_opt) catch @panic("OOM");
    }
    const ocamlopt_opt = self.linkOcamloptOpt(self.build_platform, self.build_platform, target);
    const fast_opt = self.rawOcamlopt(null, ocamlopt_opt, target);
    self.raw_emitters.put(b.allocator, target.triplet, fast_opt) catch @panic("OOM");
    return fast_opt;
}

fn rawOcamlopt(self: *Ocaml, ocamlrun: ?*std.Build.Step.Compile, exe: LazyPath, target: Platform) Ocamlopt {
    return .{
        .b = self.src.b,
        .ocamlrun = ocamlrun,
        .exe = exe,
        .stdlib_dir = null,
        .flexlink = if (target.is_windows) self.getRuntime(target).flexlink.? else null,
        .prefix_map = self.src.prefixMap(),
        .cwd = self.src.path(""),
    };
}

fn getEmitter(self: *Ocaml, target: Platform) Ocamlopt {
    var opt = self.getRawEmitter(target);
    opt.stdlib_dir = self.getStdlib(target).dir;
    return opt;
}

fn getArchByte(self: *Ocaml, arch: ?Platform.Arch) compiler.ArchByte {
    if (self.arch_bytes.get(arch)) |ab| return ab;
    const ab = compiler.buildArchByte(self.src, self.comp_shared, arch);
    self.arch_bytes.put(self.src.b.allocator, arch, ab) catch @panic("OOM");
    return ab;
}

fn getByteCommon(self: *Ocaml, host: Platform, target: Platform) compiler.ByteCommon {
    const b = self.src.b;
    const key = b.fmt("{s}->{s}", .{ host.triplet, target.triplet });
    if (self.byte_commons.get(key)) |bc| return bc;
    const bc = compiler.buildByteCommon(self.src, self.comp_shared, self.getArchByte(target.arch), host, target, self.launchInfo(host));
    self.byte_commons.put(b.allocator, key, bc) catch @panic("OOM");
    return bc;
}

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

fn getNativeCompiler(self: *Ocaml, code: Platform, target_arch: ?Platform.Arch) compiler.ArchNative {
    const b = self.src.b;
    const key = b.fmt("{s}->{s}", .{ self.codeKey(code), if (target_arch) |a| @tagName(a) else "none" });
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
    self.native_compilers.put(b.allocator, key, an) catch @panic("OOM");
    return an;
}

fn getOcamllexOpt(self: *Ocaml, host: Platform) LazyPath {
    if (self.ocamllex_opts.get(host.triplet)) |p| return p;
    const arch_nat = self.getNativeCompiler(host, host.arch);
    const p = compiler.linkOcamllexOpt(
        self.src.b,
        self.src.manifest,
        self.getArchByte(host.arch),
        arch_nat.lex_compiled.?,
        self.getEmitter(host),
        self.getRuntime(host),
    );
    self.ocamllex_opts.put(self.src.b.allocator, host.triplet, p) catch @panic("OOM");
    return p;
}

fn getNativeCommon(self: *Ocaml, code: Platform, host: Platform, target: Platform) compiler.NativeCommon {
    const b = self.src.b;
    const key = b.fmt("{s}:{s}->{s}", .{ self.codeKey(code), host.triplet, target.triplet });
    if (self.native_commons.get(key)) |nc| return nc;
    const nc = compiler.buildNativeCommon(
        self.src,
        self.getArchByte(target.arch),
        self.getNativeCompiler(code, target.arch),
        self.getByteCommon(host, target).config_main_ml,
        self.getEmitter(code),
    );
    self.native_commons.put(b.allocator, key, nc) catch @panic("OOM");
    return nc;
}

fn linkOcamloptOpt(self: *Ocaml, code: Platform, host: Platform, target: Platform) LazyPath {
    return compiler.linkOcamloptOpt(
        self.src.b,
        self.getArchByte(target.arch),
        self.getNativeCompiler(code, target.arch),
        self.getNativeCommon(code, host, target),
        self.getEmitter(code),
        self.getRuntime(code),
    );
}

fn getOcamlnat(self: *Ocaml, target: Platform) LazyPath {
    if (self.ocamlnats.get(target.triplet)) |p| return p;
    const p = extras.linkOcamlnat(
        self.src.b,
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

fn getDebugger(self: *Ocaml, host: Platform, target: Platform) extras.DebuggerArtifacts {
    const base = self.getDebuggerByte(target);
    return extras.linkDebugger(
        self.src,
        base,
        self.ocamlcFor(host, target),
        self.getArchByte(target.arch),
        self.getByteCommon(host, target),
        self.getOtherlibs(target),
        host,
        self.launchInfo(host),
    );
}

fn getDebuggerByte(self: *Ocaml, target: Platform) extras.DebuggerByte {
    if (self.debugger_byte) |db| return db;
    const arch_byte = self.getArchByte(target.arch);
    const db = extras.compileDebugger(
        self.src,
        self.ocamlcFor(target, target),
        arch_byte.sources,
        arch_byte.compiled.cmis_dir,
        self.getOtherlibs(target),
    );
    self.debugger_byte = db;
    return db;
}

fn getOcamldoc(self: *Ocaml, host: Platform, target: Platform) extras.OcamldocArtifacts {
    const odoc_byte = self.getOcamldocByte(target);
    const odoc_nat: ?extras.OcamldocNative = if (target.hasNativeCompiler())
        self.getOcamldocNative(target)
    else
        null;
    return extras.linkOcamldoc(
        self.src,
        odoc_byte,
        odoc_nat,
        self.ocamlcFor(host, target),
        self.getByteCommon(host, target).ocamlcommon_cma,
        self.getOtherlibs(target),
        target,
        host,
        self.launchInfo(host),
    );
}

fn getOcamldocByte(self: *Ocaml, target: Platform) extras.OcamldocByte {
    if (self.odoc_byte) |ob| return ob;
    const arch_byte = self.getArchByte(target.arch);
    const ob = extras.compileOcamldocByte(
        self.src,
        self.ocamlcFor(target, target),
        arch_byte.sources,
        arch_byte.compiled.cmis_dir,
        self.getOtherlibs(target),
    );
    self.odoc_byte = ob;
    return ob;
}

fn getOcamldocNative(self: *Ocaml, target: Platform) extras.OcamldocNative {
    if (self.odoc_nats.get(target.triplet)) |on| return on;
    const odoc_byte = self.getOcamldocByte(target);
    const arch_byte = self.getArchByte(target.arch);
    const arch_nat = self.getNativeCompiler(target, target.arch);
    const nat_common = self.getNativeCommon(target, target, target);
    const on = extras.compileOcamldocNative(
        self.src,
        odoc_byte,
        self.getEmitter(target),
        arch_byte.compiled.cmis_dir,
        arch_nat,
        nat_common,
        self.getOtherlibs(target),
        self.getRuntime(target),
    );
    self.odoc_nats.put(self.src.b.allocator, target.triplet, on) catch @panic("OOM");
    return on;
}

fn getFlexlinkByte(self: *Ocaml) flexdll.Byte {
    if (self.flexlink_byte) |fb| return fb;
    const fb = flexdll.compileByte(self.comp_shared.boot);
    self.flexlink_byte = fb;
    return fb;
}

fn getFlexlinkOpt(self: *Ocaml, host: Platform) LazyPath {
    if (self.flexlink_opts.get(host.triplet)) |p| return p;
    const p = flexdll.linkNative(self.getEmitter(host), self.getFlexlinkByte(), self.getRuntime(host));
    self.flexlink_opts.put(self.src.b.allocator, host.triplet, p) catch @panic("OOM");
    return p;
}

fn buildFlexlink(self: *Ocaml) LazyPath {
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

fn codeKey(self: *Ocaml, p: Platform) []const u8 {
    return self.src.b.fmt("{s}-{s}", .{ p.archName(), p.system });
}

const Layout = union(enum) {
    install: struct {
        b: *std.Build,
        step: *std.Build.Step,
        sub_path: []const u8,
    },
    wf: struct {
        b: *std.Build,
        wf: *std.Build.Step.WriteFile,
    },

    fn b(self: Layout) *std.Build {
        return switch (self) {
            .install => |i| i.b,
            .wf => |w| w.b,
        };
    }

    fn file(self: Layout, src: LazyPath, dest: []const u8) void {
        switch (self) {
            .install => |i| {
                const rel = if (i.sub_path.len == 0) dest else i.b.fmt("{s}/{s}", .{ i.sub_path, dest });
                i.step.dependOn(&i.b.addInstallFileWithDir(src, .prefix, rel).step);
            },
            .wf => |w| {
                _ = w.wf.addCopyFile(src, dest);
            },
        }
    }

    fn dir(self: Layout, src: LazyPath, dest: []const u8, exclude_extensions: []const []const u8) void {
        switch (self) {
            .install => |i| {
                const rel = if (i.sub_path.len == 0) dest else i.b.fmt("{s}/{s}", .{ i.sub_path, dest });
                i.step.dependOn(&i.b.addInstallDirectory(.{
                    .source_dir = src,
                    .install_dir = .prefix,
                    .install_subdir = rel,
                    .exclude_extensions = exclude_extensions,
                }).step);
            },
            .wf => |w| {
                _ = w.wf.addCopyDirectory(src, dest, .{ .exclude_extensions = exclude_extensions });
            },
        }
    }

    /// Install a compiled artifact, using `lib<name>.a` for static archives (as OCaml expects on mingw).
    fn artifact(self: Layout, a: *std.Build.Step.Compile, dest_dir: []const u8) void {
        const builder = self.b();
        const name = if (a.kind == .lib and a.linkage == .static)
            builder.fmt("lib{s}.a", .{a.name})
        else
            a.out_filename;
        self.file(a.getEmittedBin(), builder.fmt("{s}/{s}", .{ dest_dir, name }));
    }
};
