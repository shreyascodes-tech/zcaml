//! Build an OCaml toolchain from source with Zig.
//!
//! ```zig
//! const ocaml_versions: Ocaml.Versions = .init(b);
//! const src = ocaml_versions.source(.@"5.5.1") orelse return;
//! const toolchain = Ocaml.build(src, .{ .host = host, .target = target, .optimize = optimize });
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
const otherlibs = @import("otherlibs.zig");
pub const Source = @import("source.zig");
pub const Platform = @import("platform.zig");
pub const Versions = @import("versions.zig");
pub const Version = Versions.Version;
pub const resolveTarget = Platform.resolveTarget;

pub const Options = struct {
    /// Where the compilers run.
    host: std.Build.ResolvedTarget,
    /// Where the programs they produce run.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ocamldoc: bool = false,
    ocamldebug: bool = false,
    ocamlnat: bool = false,
    bytecode_tools: bool = false,
    runtime_variants: bool = false,
};

pub const Toolchain = struct {
    b: *std.Build,
    /// The install tree, see the module docs.
    layout: std.Build.LazyPath,
    host_rt: runtime.Artifacts,
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    compiler: compiler.Artifacts,
    otherlibs: otherlibs.Artifacts,
    ocamldebug: ?compiler.DebuggerArtifacts = null,
    ocamldoc: ?compiler.OcamldocArtifacts = null,
    options: Options,

    /// Install the layout to `<install prefix>/<sub_path>`.
    pub fn addInstall(self: Toolchain, step: *std.Build.Step, sub_path: []const u8) void {
        step.dependOn(&self.b.addInstallDirectory(.{
            .source_dir = self.layout,
            .install_dir = .prefix,
            .install_subdir = sub_path,
        }).step);
    }
};

/// Get `src` from `Versions.source`.
pub fn build(src: *const Source, options: Options) Toolchain {
    const b = src.b;
    const build_platform: Platform = .init(b, b.graph.host);
    const host: Platform = .init(b, options.host);
    const target: Platform = .init(b, options.target);

    // Runtimes for the target (installed), the build machine (runs boot/ocamlc etc.),
    // and the compiler host (runs the installed compilers), deduplicated.
    const target_rt = runtime.build(src.*, .{ .platform = target, .optimize = options.optimize, .variants = options.runtime_variants });
    const build_rt = if (target.eql(build_platform))
        target_rt
    else
        runtime.build(src.*, .{ .platform = build_platform, .optimize = options.optimize });
    const host_rt = if (host.eql(target))
        target_rt
    else if (host.eql(build_platform))
        build_rt
    else
        runtime.build(src.*, .{ .platform = host, .optimize = options.optimize, .variants = options.runtime_variants });

    const byte_stdlib = stdlib.build(src, .{
        .target_rt = target_rt,
        .build_ocamlrun = build_rt.ocamlrun,
    });
    var comp = compiler.build(src, .{
        .host = host,
        .target_rt = target_rt,
        .stdlib = byte_stdlib,
        .build_ocamlrun = build_rt.ocamlrun,
        .build_ocamlyacc = build_rt.ocamlyacc,
    });
    const std_lib = stdlib.buildNative(src, byte_stdlib, comp.ocamlopt, target);
    comp.ocamlopt.stdlib_dir = std_lib.dir;
    const libs = otherlibs.build(src, .{
        .target_rt = target_rt,
        .stdlib = std_lib,
        .compiler = comp,
        .optimize = options.optimize,
    });
    if (target.hasNativeCompiler()) {
        // Installed compiler-libs contain target code, not compiler-host code.
        comp = compiler.buildNative(src, comp, comp.ocamlopt, target_rt, libs.dynlink_dir, host.eql(target));
    }
    if (host.hasNativeCompiler() and !host.eql(target)) {
        // Bootstrap a host-targeting emitter, then use it on the original
        // host->target compiler sources to produce runnable host executables.
        const host_byte_stdlib = stdlib.build(src, .{ .target_rt = host_rt, .build_ocamlrun = build_rt.ocamlrun });
        var host_comp = compiler.build(src, .{
            .host = host,
            .target_rt = host_rt,
            .stdlib = host_byte_stdlib,
            .build_ocamlrun = build_rt.ocamlrun,
            .build_ocamlyacc = build_rt.ocamlyacc,
        });
        const host_stdlib = stdlib.buildNative(src, host_byte_stdlib, host_comp.ocamlopt, host);
        host_comp.ocamlopt.stdlib_dir = host_stdlib.dir;
        const host_native = compiler.buildNative(src, comp, host_comp.ocamlopt, host_rt, null, true);
        comp.native_programs = host_native.native_programs;
    }

    const ocamldebug = if (options.ocamldebug)
        compiler.buildDebugger(src, comp, libs, host, build_rt.ocamlrun, build_rt.ocamlyacc)
    else
        null;
    const ocamldoc = if (options.ocamldoc)
        compiler.buildOcamldoc(src, comp, libs, target_rt, host, build_rt.ocamlrun, build_rt.ocamlyacc)
    else
        null;

    var tc: Toolchain = .{
        .b = b,
        .layout = undefined,
        .host_rt = host_rt,
        .target_rt = target_rt,
        .stdlib = std_lib,
        .compiler = comp,
        .otherlibs = libs,
        .ocamldebug = ocamldebug,
        .ocamldoc = ocamldoc,
        .options = options,
    };
    tc.layout = assembleLayout(src.*, tc);
    return tc;
}

const Layout = struct {
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,

    fn file(self: Layout, src: std.Build.LazyPath, dest: []const u8) void {
        _ = self.wf.addCopyFile(src, dest);
    }

    fn dir(self: Layout, src: std.Build.LazyPath, dest: []const u8, exclude_extensions: []const []const u8) void {
        _ = self.wf.addCopyDirectory(src, dest, .{ .exclude_extensions = exclude_extensions });
    }

    /// Install a compiled artifact under its native file name (`libfoo.a`, `foo.lib`, ...).
    fn artifact(self: Layout, a: *std.Build.Step.Compile, dest_dir: []const u8) void {
        self.file(a.getEmittedBin(), self.b.fmt("{s}/{s}", .{ dest_dir, a.out_filename }));
    }
};

fn assembleLayout(src: Source, tc: Toolchain) std.Build.LazyPath {
    const b = src.b;
    const target = tc.target_rt.platform;
    const layout: Layout = .{ .b = b, .wf = b.addNamedWriteFiles("ocaml-layout") };
    const bin = "bin";
    const lib = "lib/ocaml";

    // bin/: host runtime and tools (.opt defaults, with .byte always retained)
    layout.artifact(tc.host_rt.ocamlrun, bin);
    if (tc.host_rt.ocamlrund) |a| layout.artifact(a, bin);
    if (tc.host_rt.ocamlruni) |a| layout.artifact(a, bin);
    layout.artifact(tc.host_rt.ocamlyacc, bin);
    if (!tc.host_rt.platform.eql(target)) {
        layout.file(tc.target_rt.ocamlrun.getEmittedBin(), b.fmt("{s}/ocamlrun-target{s}", .{ bin, target.exeExt() }));
        if (tc.target_rt.ocamlrund) |a| layout.file(a.getEmittedBin(), b.fmt("{s}/ocamlrund-target{s}", .{ bin, target.exeExt() }));
        if (tc.target_rt.ocamlruni) |a| layout.file(a.getEmittedBin(), b.fmt("{s}/ocamlruni-target{s}", .{ bin, target.exeExt() }));
    }

    const progs = tc.compiler.programs;
    // also installed as `<name>.byte`, upstream's name for the bytecode build
    // (ocamlc.byte and ocamlopt.byte are debug-stripped, matching upstream install)
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "ocamlc", progs.ocamlc_stripped },
        .{ "ocamlopt", progs.ocamlopt_stripped },
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
        layout.file(native orelse entry[1], b.fmt("{s}/{s}", .{ bin, entry[0] }));
        if (native) |exe| layout.file(exe, b.fmt("{s}/{s}.opt", .{ bin, entry[0] }));
        layout.file(entry[1], b.fmt("{s}/{s}.byte", .{ bin, entry[0] }));
    }
    if (tc.options.ocamlnat) {
        if (tc.compiler.ocamlnat) |exe| layout.file(exe, b.fmt("{s}/ocamlnat", .{bin}));
    }
    if (tc.ocamldebug) |dbg| {
        layout.file(dbg.exe, b.fmt("{s}/ocamldebug", .{bin}));
        layout.file(dbg.cmi, lib ++ "/compiler-libs/ocamldebug.cmi");
        layout.file(dbg.parser_aux_cmi, lib ++ "/compiler-libs/parser_aux.cmi");
    }
    if (tc.ocamldoc) |odoc| {
        const default_odoc = if (tc.host_rt.platform.eql(target)) odoc.opt orelse odoc.byte else odoc.byte;
        layout.file(default_odoc, b.fmt("{s}/ocamldoc", .{bin}));
        if (odoc.opt) |exe| layout.file(exe, b.fmt("{s}/ocamldoc.opt", .{bin}));
        layout.file(odoc.byte, b.fmt("{s}/ocamldoc.byte", .{bin}));
        layout.dir(odoc.lib_dir, lib ++ "/ocamldoc", &.{});
    }
    if (tc.options.bytecode_tools) {
        for ([_]struct { []const u8, std.Build.LazyPath }{
            .{ "cmpbyt", progs.cmpbyt },
            .{ "dumpobj", progs.dumpobj },
            .{ "primreq", progs.primreq },
            .{ "stripdebug", progs.stripdebug },
        }) |entry| {
            layout.file(entry[1], b.fmt("{s}/{s}", .{ bin, entry[0] }));
        }
    }
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "ocamlcmt", progs.ocamlcmt },
        .{ "ocamlprof", progs.ocamlprof },
        .{ "ocamlcp", progs.ocamlcp },
        .{ "ocamloptp", progs.ocamloptp },
        .{ "ocamlmklib", progs.ocamlmklib },
        .{ "ocamlmktop", progs.ocamlmktop },
        .{ "ocaml", progs.ocaml },
    }) |entry| {
        layout.file(entry[1], b.fmt("{s}/{s}", .{ bin, entry[0] }));
    }
    layout.file(progs.expunge, lib ++ "/expunge");

    // lib/ocaml/: target runtime libraries, primitives, ld.conf, C headers
    layout.artifact(tc.target_rt.libcamlrun, lib);
    if (tc.target_rt.libcamlrun_pic) |a| layout.artifact(a, lib);
    if (tc.target_rt.libcamlrun_shared) |a| layout.artifact(a, lib);
    if (tc.target_rt.libcamlrund) |a| layout.artifact(a, lib);
    if (tc.target_rt.libcamlruni) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrun) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrun_pic) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrun_shared) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrund) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmruni) |a| layout.artifact(a, lib);
    layout.artifact(tc.target_rt.libcomprmarsh, lib);
    layout.artifact(tc.target_rt.zstd_lib, lib);
    layout.file(tc.target_rt.primitives, lib ++ "/primitives");
    layout.file(b.addWriteFiles().add("ld.conf", "./stublibs\n.\n"), lib ++ "/ld.conf");
    layout.dir(src.path("runtime/caml"), lib ++ "/caml", &.{ ".in", "dune" });
    layout.dir(tc.target_rt.headers_dir.path(b, "caml"), lib ++ "/caml", &.{});

    // stdlib (flat in lib/ocaml/, as upstream)
    layout.dir(tc.stdlib.dir, lib, &.{});
    layout.file(tc.stdlib.meta, lib ++ "/stdlib/META");

    // compiler-libs, profiling
    layout.dir(tc.compiler.compilerlibs_dir, lib ++ "/compiler-libs", &.{});
    layout.dir(tc.compiler.profiling_dir, lib ++ "/profiling", &.{});

    // otherlibs: lib/ocaml/<lib>/, C stubs in lib/ocaml/ and lib/ocaml/stublibs/
    for (tc.otherlibs.libs) |l| {
        layout.dir(l.dir, b.fmt("{s}/{s}", .{ lib, l.name }), &.{});
        const stubs = l.stubs orelse continue;
        layout.artifact(stubs.static_byt, lib);
        layout.artifact(stubs.static_nat, lib);
        if (stubs.shared_byt) |dll| layout.file(dll.getEmittedBin(), b.fmt("{s}/stublibs/{s}", .{ lib, stubs.dllName(target) }));
    }
    for (tc.otherlibs.headers) |h| layout.file(h.source, b.fmt("{s}/caml/{s}", .{ lib, h.dest_name }));

    return layout.wf.getDirectory();
}
