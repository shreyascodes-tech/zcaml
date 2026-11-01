//! Bootstrap bytecode compilers and tools, followed by native `compiler-libs`
//! and host-native `.opt` executables.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const Ocamlc = @import("ocamlc.zig");
const Ocamlopt = @import("ocamlopt.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const otherlibs = @import("otherlibs.zig");
const Tools = @import("tools/root.zig");
const LazyPath = std.Build.LazyPath;

pub const Artifacts = struct {
    /// Bytecode executables, to be run by the host `ocamlrun`.
    programs: Programs,
    compilerlibs_dir: LazyPath,
    profiling_dir: LazyPath,
    /// Source resolver for compiler modules.
    sources: Source.Resolver,
    /// The freshly built `ocamlc`, for compiling libraries against the new stdlib.
    ocamlc: Ocamlc,
    ocamlopt: Ocamlopt,
    compiled: Ocamlc.Compiled,
    lex: Ocamlc.Compiled,
    native_programs: ?NativePrograms = null,
    ocamlnat: ?LazyPath = null,
};

pub const Programs = struct {
    ocamlc: LazyPath,
    ocamlc_stripped: LazyPath,
    ocamlopt: LazyPath,
    ocamlopt_stripped: LazyPath,
    ocamllex: LazyPath,
    ocamldep: LazyPath,
    ocamlobjinfo: LazyPath,
    ocamlcmt: LazyPath,
    ocamlprof: LazyPath,
    ocamlcp: LazyPath,
    ocamloptp: LazyPath,
    ocamlmklib: LazyPath,
    ocamlmktop: LazyPath,
    cmpbyt: LazyPath,
    dumpobj: LazyPath,
    primreq: LazyPath,
    stripdebug: LazyPath,
    expunge: LazyPath,
    /// The toplevel (`ocaml`).
    ocaml: LazyPath,
};

pub const NativePrograms = struct {
    ocamlc: LazyPath,
    ocamlopt: LazyPath,
    ocamllex: LazyPath,
    ocamldep: LazyPath,
    ocamlobjinfo: LazyPath,
};

pub const OcamldocByte = struct {
    sources: Source.Resolver,
    compiled: Ocamlc.Compiled,
    byte_lib_dir: LazyPath,
    odoc_info_cma: LazyPath,
    prog_cmos: []const LazyPath,
};

pub const OcamldocNative = struct {
    lib_dir: LazyPath,
    nat_dir: LazyPath,
    odoc_info_cmxa: LazyPath,
    prog_cmxs: []const LazyPath,
};

pub const OcamldocArtifacts = struct {
    byte: LazyPath,
    opt: ?LazyPath = null,
    lib_dir: LazyPath,
    cmis_dir: LazyPath,
    odoc_info_cma: LazyPath,
    prog_cmos: []const LazyPath,
};

pub const DebuggerArtifacts = struct {
    exe: LazyPath,
    cmi: LazyPath,
    parser_aux_cmi: LazyPath,
    cmis_dir: LazyPath,
    packed_cmo: LazyPath,
    entry_cmo: LazyPath,
};

pub const Options = struct {
    /// Where the compilers run.
    host: Platform,
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    host_launch_info_dir: ?LazyPath = null,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
};

/// Target- and host-independent compiler bootstrap artifacts, built once per OCaml release.
pub const Shared = struct {
    config_common: []const u8,
    compilerlibs_meta: LazyPath,
    base_sources: Source.Resolver,
    cvt_emit: LazyPath,
    boot: Ocamlc,
    lex: Ocamlc.Compiled,
    build_ocamlrun: *std.Build.Step.Compile,
};

/// Architecture-dependent bytecode compiler artifacts (`boot/ocamlc` output), built once per `Arch`.
pub const ArchByte = struct {
    arch: ?Platform.Arch,
    sources: Source.Resolver,
    compiled: Ocamlc.Compiled,
    base_compilerlibs_dir: LazyPath,
    profiling_dir: LazyPath,
    ocamlbytecomp_cma: LazyPath,
    ocamlmiddleend_cma: LazyPath,
    ocamloptcomp_cma: LazyPath,
    ocamltoplevel_cma: LazyPath,
};

/// Architecture-dependent native compiler artifacts (`ocamlopt` output), built once per `(arch, system)` or `(host, target_arch)`.
pub const ArchNative = struct {
    compiled: Ocamlopt.Compiled,
    bytecomp_cmxa: LazyPath,
    middleend_cmxa: LazyPath,
    optcomp_cmxa: LazyPath,
    toplevel_cmxa: ?LazyPath,
    base_libs_dir: ?LazyPath,
    profiling_dir: ?LazyPath,
    lex: ?Ocamlopt.Compiled = null,
};

/// Default stdlib location, relative to `bin/`.
pub const stdlib_dir_from_bin = "../lib/ocaml";

pub fn buildShared(
    src: *const Source,
    stdlib_base_dir: LazyPath,
    build_launch_info_dir: LazyPath,
    primitives: LazyPath,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
) Shared {
    const b = src.b;
    const m = src.manifest;

    const config_common = renderConfigCommon(src.*);
    const config_wf = b.addWriteFiles();
    const compilerlibs_meta = config_wf.add("META", src.renderMeta("compilerlibs/META.in", &.{}));

    const gen, _ = Tools.run(b, .gen_compiler_sources, .{
        .ocaml_src_dir = .of(src.path("")),
        .primitives = .of(primitives),
        .arch64 = true,
        .domainstate_ml = .of("domainstate.ml"),
        .domainstate_mli = .of("domainstate.mli"),
        .runtimedef_ml = .of("runtimedef.ml"),
        .menhir_lib_mli = .of("camlinternalMenhirLib.mli"),
        .parser_ml = .of("parser.ml"),
        .parser_mli = .of("parser.mli"),
    });

    const yacc_run = b.addRunArtifact(build_ocamlyacc);
    yacc_run.addArgs(&.{ "--strict", "-b" });
    const yacc_prefix = yacc_run.addOutputFileArg("parser");
    yacc_run.addFileArg(src.path("lex/parser.mly"));

    const lexer: Lexer = .{ .b = b, .ocamlrun = build_ocamlrun, .exe = src.path("boot/ocamllex") };

    const boot: Ocamlc = .{
        .b = b,
        .ocamlrun = build_ocamlrun,
        .exe = src.path("boot/ocamlc"),
        .stdlib_dir = stdlib_base_dir,
        .primitives = primitives,
        .prefix_map = src.prefixMap(),
        .cwd = src.path(""),
    };
    const make_opcodes = buildTool(boot, lexer.run(src.path("tools/make_opcodes.mll"), "make_opcodes.ml"), "make_opcodes", build_launch_info_dir);
    const cvt_emit = buildTool(boot, lexer.run(src.path("tools/cvt_emit.mll"), "cvt_emit.ml"), "cvt_emit", build_launch_info_dir);
    const instruct_h = src.path("runtime/caml/instruct.h");

    const opcodes_ml = runCapture(b, build_ocamlrun, make_opcodes, &.{"-opcodes"}, instruct_h);
    const opnames_ml = runCapture(b, build_ocamlrun, make_opcodes, &.{"-opnames"}, instruct_h);
    const opcodes_mli = blk: {
        const run = boot.cmd(.{ .flags = &.{ "-i", "-impl" } });
        run.addFileArg(opcodes_ml);
        break :blk run.captureStdOut(.{});
    };

    var base_sources: Source.Resolver = .{ .source = src, .arch = null };
    base_sources.gen.put(.domainstate_ml, gen.domainstate_ml.lazyPath());
    base_sources.gen.put(.domainstate_mli, gen.domainstate_mli.lazyPath());
    base_sources.gen.put(.runtimedef_ml, gen.runtimedef_ml.lazyPath());
    base_sources.gen.put(.camlinternalMenhirLib_mli, gen.menhir_lib_mli.lazyPath());
    base_sources.gen.put(.parser_ml, gen.parser_ml.lazyPath());
    base_sources.gen.put(.parser_mli, gen.parser_mli.lazyPath());
    base_sources.gen.put(.parsing_lexer_ml, lexer.run(src.path("parsing/lexer.mll"), "lexer.ml"));
    base_sources.gen.put(.byterntm_ml, lexer.run(src.path("bytecomp/byterntm.mll"), "byterntm.ml"));
    base_sources.gen.put(.opcodes_ml, opcodes_ml);
    base_sources.gen.put(.opcodes_mli, opcodes_mli);
    base_sources.gen.put(.opnames_ml, opnames_ml);
    base_sources.gen.put(.lex_parser_ml, yacc_prefix.dirname().path(b, "parser.ml"));
    base_sources.gen.put(.lex_parser_mli, yacc_prefix.dirname().path(b, "parser.mli"));
    base_sources.gen.put(.lex_lexer_ml, lexer.run(src.path("lex/lexer.mll"), "lexer.ml"));

    const lex = boot.compilePlan(m.lex.plan, base_sources, .{ .flags = m.compiler.compflags });

    return .{
        .config_common = config_common,
        .compilerlibs_meta = compilerlibs_meta,
        .base_sources = base_sources,
        .cvt_emit = cvt_emit,
        .boot = boot,
        .lex = lex,
        .build_ocamlrun = build_ocamlrun,
    };
}

pub fn buildArchByte(src: *const Source, shared: Shared, arch: ?Platform.Arch, frontend: ?ArchByte) ArchByte {
    const b = src.b;
    const cc = src.manifest.compiler;
    const arch_name = if (arch) |a| @tagName(a) else "none";

    var sources = shared.base_sources;
    sources.arch = arch;
    if (arch != null) {
        const body = runCapture(b, shared.build_ocamlrun, shared.cvt_emit, &.{}, src.path(b.fmt("asmcomp/{s}/emit.mlp", .{arch_name})));
        const prep, _ = Tools.run(b, .prepend_emit_line, .{
            .cvt_emit_output = .of(body),
            .arch = arch_name,
            .out_emit_ml = .of("emit.ml"),
        });
        sources.gen.put(.emit_ml, prep.out_emit_ml.lazyPath());
    }

    const compiled = shared.boot.compilePlan(cc.plan, sources, .{
        .flags = cc.compflags,
        .reuse_frontend = if (frontend) |fe| fe.compiled else null,
    });

    const compilerlibs = b.addWriteFiles();
    _ = compilerlibs.addCopyFile(shared.compilerlibs_meta, "META");
    const profiling = b.addWriteFiles();

    for (compiled.intfs.values()) |u| {
        const dest = switch (u.unit.dest) {
            .none => continue,
            .lib => compilerlibs,
            .profiling => profiling,
        };
        _ = dest.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        if (u.cmti) |cmti| {
            _ = dest.addCopyFile(cmti, b.fmt("{s}.cmti", .{u.unit.name}));
            if (dest == compilerlibs) _ = dest.addCopyFile(u.src, b.fmt("{s}.mli", .{u.unit.name}));
        }
    }
    for (compiled.impls.values()) |u| {
        switch (u.unit.dest) {
            .none => {},
            .lib => _ = compilerlibs.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name})),
            .profiling => {
                _ = profiling.addCopyFile(u.impl.cmo, b.fmt("{s}.cmo", .{u.unit.name}));
                _ = profiling.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name}));
            },
        }
    }
    for ([_][]const u8{ "driver/main", "driver/optmain", "toplevel/topstart" }) |key| {
        _ = compilerlibs.addCopyFile(compiled.cmo(key).?, b.fmt("{s}.cmo", .{std.fs.path.basename(key)}));
    }

    const archive = struct {
        fn f(o: Ocamlc, c: Ocamlc.Compiled, wf: *std.Build.Step.WriteFile, name: []const u8, keys: []const []const u8) LazyPath {
            const cma = o.archive(name, c.cmos(o.b, keys), .{});
            _ = wf.addCopyFile(cma, name);
            return cma;
        }
    }.f;

    const ocamlbytecomp = if (frontend) |fe| blk: {
        _ = compilerlibs.addCopyFile(fe.ocamlbytecomp_cma, "ocamlbytecomp.cma");
        break :blk fe.ocamlbytecomp_cma;
    } else archive(shared.boot, compiled, compilerlibs, "ocamlbytecomp.cma", cc.ocamlbytecomp);

    const ocamlmiddleend = if (frontend) |fe| blk: {
        _ = compilerlibs.addCopyFile(fe.ocamlmiddleend_cma, "ocamlmiddleend.cma");
        break :blk fe.ocamlmiddleend_cma;
    } else archive(shared.boot, compiled, compilerlibs, "ocamlmiddleend.cma", cc.ocamlmiddleend);

    const ocamltoplevel = if (frontend) |fe| blk: {
        _ = compilerlibs.addCopyFile(fe.ocamltoplevel_cma, "ocamltoplevel.cma");
        break :blk fe.ocamltoplevel_cma;
    } else archive(shared.boot, compiled, compilerlibs, "ocamltoplevel.cma", cc.ocamltoplevel);

    const ocamloptcomp = archive(shared.boot, compiled, compilerlibs, "ocamloptcomp.cma", cc.ocamloptcomp);

    return .{
        .arch = arch,
        .sources = sources,
        .compiled = compiled,
        .base_compilerlibs_dir = compilerlibs.getDirectory(),
        .profiling_dir = if (frontend) |fe| fe.profiling_dir else profiling.getDirectory(),
        .ocamlbytecomp_cma = ocamlbytecomp,
        .ocamlmiddleend_cma = ocamlmiddleend,
        .ocamloptcomp_cma = ocamloptcomp,
        .ocamltoplevel_cma = ocamltoplevel,
    };
}

pub fn buildFromArchByte(
    src: *const Source,
    shared: Shared,
    arch_byte: ArchByte,
    host: Platform,
    target: Platform,
    host_launch_info_dir: LazyPath,
    target_stdlib_dir: LazyPath,
) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const cc = m.compiler;
    const boot = shared.boot;

    const config_wf = b.addWriteFiles();
    const config_main_ml = config_wf.add("config_main.ml", b.fmt("{s}\n{s}", .{ renderConfigGenerated(src.*, host, target), shared.config_common }));
    var sources = arch_byte.sources;
    sources.gen.put(.config_main_ml, config_main_ml);

    const cfg_intf = arch_byte.compiled.intfs.get("utils/config").?;
    const cfg_impl = boot.impl(config_main_ml, "config", cfg_intf.cmi, .{
        .includes = &.{arch_byte.compiled.cmis_dir},
        .flags = cc.compflags,
    });

    var compiled = arch_byte.compiled;
    compiled.impls = arch_byte.compiled.impls.clone(b.allocator) catch @panic("OOM");
    compiled.impls.put(b.allocator, "utils/config", .{ .unit = cfg_intf.unit, .src = config_main_ml, .impl = cfg_impl }) catch @panic("OOM");

    const ocamlcommon = boot.archive("ocamlcommon.cma", compiled.cmos(b, cc.ocamlcommon), .{ .flags = &.{"-linkall"} });
    const compilerlibs = b.addWriteFiles();
    _ = compilerlibs.addCopyDirectory(arch_byte.base_compilerlibs_dir, "", .{});
    _ = compilerlibs.addCopyFile(cfg_impl.cmt, "config.cmt");
    _ = compilerlibs.addCopyFile(ocamlcommon, "ocamlcommon.cma");

    const ocamlbytecomp = arch_byte.ocamlbytecomp_cma;
    const ocamlmiddleend = arch_byte.ocamlmiddleend_cma;
    const ocamloptcomp = arch_byte.ocamloptcomp_cma;
    const ocamltoplevel = arch_byte.ocamltoplevel_cma;

    const launch_flags = launchFlags(b, host);
    const linker: Linker = .{ .ocamlc = boot, .includes = &.{ compiled.cmis_dir, host_launch_info_dir }, .launch_flags = launch_flags };
    const cmo = struct {
        fn f(c: Ocamlc.Compiled, key: []const u8) LazyPath {
            return c.cmo(key).?;
        }
    }.f;

    const expunge = linker.link("expunge.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "toplevel/expunge") }, &.{});
    const ocaml_tmp = linker.link("ocaml.tmp", &.{ ocamlcommon, ocamlbytecomp, ocamltoplevel, cmo(compiled, "toplevel/topstart") }, &.{ "-linkall", "-g" });
    const ocaml = blk: {
        const run = b.addRunArtifact(shared.build_ocamlrun);
        run.addFileArg(expunge);
        run.addFileArg(ocaml_tmp);
        const out = run.addOutputFileArg("ocaml");
        run.addArgs(m.stdlib.pervasives);
        break :blk out;
    };

    const lex = shared.lex;
    const lex_linker: Linker = .{ .ocamlc = boot, .includes = &.{ lex.cmis_dir, host_launch_info_dir }, .launch_flags = launch_flags };
    const ocamlc_byte = linker.link("ocamlc.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "driver/main") }, &.{ "-compat-32", "-g" });
    const ocamlopt_byte = linker.link("ocamlopt.byte", &.{ ocamlcommon, ocamloptcomp, cmo(compiled, "driver/optmain") }, &.{"-g"});
    const stripdebug = linker.link("stripdebug.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/stripdebug") }, &.{});
    const stripByteProg = struct {
        fn f(bb: *std.Build, ocamlrun: *std.Build.Step.Compile, strip_exe: LazyPath, prog: LazyPath, out_name: []const u8) LazyPath {
            const run = bb.addRunArtifact(ocamlrun);
            run.addFileArg(strip_exe);
            run.addFileArg(prog);
            return run.addOutputFileArg(out_name);
        }
    }.f;

    const programs: Programs = .{
        .ocamlc = ocamlc_byte,
        .ocamlc_stripped = stripByteProg(b, shared.build_ocamlrun, stripdebug, ocamlc_byte, "ocamlc.byte.stripped"),
        .ocamlopt = ocamlopt_byte,
        .ocamlopt_stripped = stripByteProg(b, shared.build_ocamlrun, stripdebug, ocamlopt_byte, "ocamlopt.byte.stripped"),
        .ocamllex = lex_linker.link("ocamllex.byte", lex.cmos(b, m.lex.ocamllex), &.{"-compat-32"}),
        .ocamldep = linker.link("ocamldep.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/ocamldep") }, &.{"-compat-32"}),
        .ocamlobjinfo = linker.link("ocamlobjinfo.byte", &.{ ocamlcommon, ocamlbytecomp, ocamlmiddleend, cmo(compiled, "tools/objinfo") }, &.{}),
        .ocamlcmt = linker.link("ocamlcmt.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/ocamlcmt") }, &.{}),
        .ocamlprof = linker.link("ocamlprof.byte", compiled.cmos(b, cc.ocamlprof), &.{}),
        .ocamlcp = linker.link("ocamlcp.byte", compiled.cmos(b, cc.ocamlcp), &.{}),
        .ocamloptp = linker.link("ocamloptp.byte", compiled.cmos(b, cc.ocamloptp), &.{}),
        .ocamlmklib = linker.link("ocamlmklib.byte", compiled.cmos(b, cc.ocamlmklib), &.{}),
        .ocamlmktop = linker.link("ocamlmktop.byte", compiled.cmos(b, cc.ocamlmktop), &.{}),
        .cmpbyt = linker.link("cmpbyt.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/cmpbyt") }, &.{}),
        .dumpobj = linker.link("dumpobj.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/opnames"), cmo(compiled, "tools/dumpobj") }, &.{}),
        .primreq = linker.link("primreq.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/primreq") }, &.{}),
        .stripdebug = stripdebug,
        .expunge = expunge,
        .ocaml = ocaml,
    };

    const prefix_map = src.prefixMap();
    return .{
        .programs = programs,
        .compilerlibs_dir = compilerlibs.getDirectory(),
        .profiling_dir = arch_byte.profiling_dir,
        .sources = sources,
        .compiled = compiled,
        .lex = lex,
        .ocamlopt = .{
            .b = b,
            .ocamlrun = shared.build_ocamlrun,
            .exe = programs.ocamlopt,
            .stdlib_dir = target_stdlib_dir,
            .prefix_map = prefix_map,
            .cwd = src.path(""),
        },
        .ocamlc = .{
            .b = b,
            .ocamlrun = shared.build_ocamlrun,
            .exe = programs.ocamlc,
            .stdlib_dir = target_stdlib_dir,
            .primitives = null,
            .prefix_map = prefix_map,
            .cwd = src.path(""),
        },
    };
}

pub fn build(src: *const Source, options: Options) Artifacts {
    const launch_dir = options.host_launch_info_dir orelse options.stdlib.launch_info_dir;
    const shared = buildShared(src, options.stdlib.dir, launch_dir, options.target_rt.primitives, options.build_ocamlrun, options.build_ocamlyacc);
    const arch_byte = buildArchByte(src, shared, options.target_rt.platform.arch, null);
    return buildFromArchByte(
        src,
        shared,
        arch_byte,
        options.host,
        options.target_rt.platform,
        launch_dir,
        options.stdlib.dir,
    );
}

pub fn buildArchNative(
    src: *const Source,
    arch_byte: ArchByte,
    lex_byte: ?Ocamlc.Compiled,
    opt: Ocamlopt,
    dynlink_dir: ?LazyPath,
    frontend: ?ArchNative,
) ArchNative {
    const b = src.b;
    const cc = src.manifest.compiler;
    const compiled = opt.compilePlan(cc.plan, arch_byte.sources, arch_byte.compiled, .{
        .includes = if (dynlink_dir) |d| &.{d} else &.{},
        .flags = cc.compflags,
        .skip_toplevel = dynlink_dir == null,
        .reuse_frontend = if (frontend) |fe| fe.compiled else null,
    });

    const libs: ?*std.Build.Step.WriteFile = if (dynlink_dir != null) b.addWriteFiles() else null;
    const profiling: ?*std.Build.Step.WriteFile = if (dynlink_dir != null) b.addWriteFiles() else null;
    if (libs) |l| {
        for (compiled.impls.values()) |u| {
            const dest = switch (u.unit.dest) {
                .none => continue,
                .lib => l,
                .profiling => profiling.?,
            };
            _ = dest.addCopyFile(u.impl.cmx, b.fmt("{s}.cmx", .{u.unit.name}));
            _ = dest.addCopyFile(u.impl.obj, b.fmt("{s}.o", .{u.unit.name}));
        }
    }

    const archive = struct {
        fn f(o: Ocamlopt, c: Ocamlopt.Compiled, wf: ?*std.Build.Step.WriteFile, name: []const u8, keys: []const []const u8, flags: []const []const u8) LazyPath {
            const a = o.archive(name, c.cmxs(o.b, keys), .{ .flags = flags });
            if (wf) |w| {
                _ = w.addCopyFile(a.cmxa, o.b.fmt("{s}.cmxa", .{name}));
                _ = w.addCopyFile(a.lib, o.b.fmt("{s}.a", .{name}));
            }
            return a.cmxa;
        }
    }.f;

    const bytecomp = if (frontend) |fe| fe.bytecomp_cmxa else archive(opt, compiled, libs, "ocamlbytecomp", cc.ocamlbytecomp, &.{});
    const middleend = if (frontend) |fe| fe.middleend_cmxa else archive(opt, compiled, libs, "ocamlmiddleend", cc.ocamlmiddleend, &.{});
    const optcomp = archive(opt, compiled, libs, "ocamloptcomp", cc.ocamloptcomp, &.{});
    const toplevel = if (libs != null) archive(opt, compiled, libs, "ocamltoplevel", cc.ocamltoplevel_native, &.{}) else null;
    const lex_nat = if (lex_byte) |lb| opt.compilePlan(src.manifest.lex.plan, arch_byte.sources, lb, .{ .flags = cc.compflags }) else null;

    return .{
        .compiled = compiled,
        .bytecomp_cmxa = bytecomp,
        .middleend_cmxa = middleend,
        .optcomp_cmxa = optcomp,
        .toplevel_cmxa = toplevel,
        .base_libs_dir = if (libs) |l| l.getDirectory() else null,
        .profiling_dir = if (profiling) |p| p.getDirectory() else null,
        .lex = lex_nat,
    };
}

pub fn finishNative(
    src: *const Source,
    byte: Artifacts,
    arch_nat: ArchNative,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
    dynlink_dir: ?LazyPath,
    programs: bool,
    ocamllex_opt: ?LazyPath,
) Artifacts {
    const b = src.b;
    const cc = src.manifest.compiler;
    const cfg_src = byte.sources.gen.get(.config_main_ml).?;
    const cfg_intf = byte.compiled.intfs.get("utils/config").?;
    const cfg_nat = opt.impl(cfg_src, "config", cfg_intf.cmi, .{
        .includes = &.{byte.compiled.cmis_dir},
        .flags = cc.compflags,
    });

    var compiled = arch_nat.compiled;
    compiled.impls = arch_nat.compiled.impls.clone(b.allocator) catch @panic("OOM");
    compiled.impls.put(b.allocator, "utils/config", .{ .unit = cfg_intf.unit, .impl = cfg_nat }) catch @panic("OOM");

    const common_archive = opt.archive("ocamlcommon", compiled.cmxs(b, cc.ocamlcommon), .{
        .flags = &.{ "-linkall", "-cclib", "-lcomprmarsh", "-cclib", "-lzstd" },
    });
    const common = common_archive.cmxa;
    const bytecomp = arch_nat.bytecomp_cmxa;
    const middleend = arch_nat.middleend_cmxa;
    const optcomp = arch_nat.optcomp_cmxa;
    const toplevel = arch_nat.toplevel_cmxa;

    var result = byte;
    if (arch_nat.base_libs_dir) |base_l| {
        const libs = b.addWriteFiles();
        _ = libs.addCopyDirectory(byte.compilerlibs_dir, "", .{});
        _ = libs.addCopyDirectory(base_l, "", .{});
        _ = libs.addCopyFile(cfg_nat.cmx, "config.cmx");
        _ = libs.addCopyFile(cfg_nat.obj, "config.o");
        _ = libs.addCopyFile(common_archive.cmxa, "ocamlcommon.cmxa");
        _ = libs.addCopyFile(common_archive.lib, "ocamlcommon.a");
        result.compilerlibs_dir = libs.getDirectory();

        const prof = b.addWriteFiles();
        _ = prof.addCopyDirectory(byte.profiling_dir, "", .{});
        _ = prof.addCopyDirectory(arch_nat.profiling_dir.?, "", .{});
        result.profiling_dir = prof.getDirectory();
    }

    if (programs) {
        const runtime_dir = b.addWriteFiles();
        _ = runtime_dir.addCopyFile(rt.libasmrun.?.getEmittedBin(), "libasmrun.a");
        _ = runtime_dir.addCopyFile(rt.libcomprmarsh.getEmittedBin(), "libcomprmarsh.a");
        _ = runtime_dir.addCopyFile(rt.zstd_lib.getEmittedBin(), "libzstd.a");
        const std_flags: []const []const u8 = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin };

        if (dynlink_dir) |ddir| if (toplevel) |tl| {
            result.ocamlnat = opt.link(
                "ocamlnat",
                &.{ common, optcomp, bytecomp, ddir.path(b, "dynlink.cmxa"), tl, compiled.impls.get("toplevel/topstart").?.impl.cmx },
                .{
                    .includes = &.{ byte.compiled.cmis_dir, compiled.dir, runtime_dir.getDirectory(), ddir },
                    .flags = Ocamlc.concat(b, std_flags, &.{"-linkall"}),
                    .strip_debug = true,
                },
            );
        };
        const lex_exe = ocamllex_opt orelse blk: {
            const lex = arch_nat.lex orelse opt.compilePlan(src.manifest.lex.plan, byte.sources, byte.lex, .{ .flags = cc.compflags });
            break :blk opt.link("ocamllex.opt", lex.cmxs(b, src.manifest.lex.ocamllex), .{
                .includes = &.{ byte.compiled.cmis_dir, compiled.dir, runtime_dir.getDirectory(), lex.dir },
                .flags = std_flags,
                .strip_debug = true,
            });
        };
        const opts: Ocamlopt.Options = .{
            .includes = &.{ byte.compiled.cmis_dir, compiled.dir, runtime_dir.getDirectory() },
            .flags = std_flags,
            .strip_debug = true,
        };
        result.native_programs = .{
            .ocamlc = opt.link("ocamlc.opt", &.{ common, bytecomp, compiled.impls.get("driver/main").?.impl.cmx }, opts),
            .ocamlopt = opt.link("ocamlopt.opt", &.{ common, optcomp, compiled.impls.get("driver/optmain").?.impl.cmx }, opts),
            .ocamllex = lex_exe,
            .ocamldep = opt.link("ocamldep.opt", &.{ common, bytecomp, compiled.impls.get("tools/ocamldep").?.impl.cmx }, opts),
            .ocamlobjinfo = opt.link("ocamlobjinfo.opt", &.{ common, bytecomp, middleend, compiled.impls.get("tools/objinfo").?.impl.cmx }, opts),
        };
    }
    return result;
}

/// `opt` determines the machine code, while `byte.sources` determines the
/// compiler's code generator. Pass `dynlink_dir = null` when only building
/// host-native cross-compiler executables (`programs = true`).
pub fn buildNative(src: *const Source, byte: Artifacts, opt: Ocamlopt, rt: runtime.Artifacts, dynlink_dir: ?LazyPath, programs: bool) Artifacts {
    var arch_byte_sources = byte.sources;
    _ = arch_byte_sources.gen.fetchRemove(.config_main_ml);
    const arch_nat = buildArchNative(src, .{
        .arch = rt.platform.arch,
        .sources = arch_byte_sources,
        .compiled = byte.compiled,
        .base_compilerlibs_dir = byte.compilerlibs_dir,
        .profiling_dir = byte.profiling_dir,
        .ocamlbytecomp_cma = undefined,
        .ocamlmiddleend_cma = undefined,
        .ocamloptcomp_cma = undefined,
        .ocamltoplevel_cma = undefined,
    }, if (programs) byte.lex else null, opt, dynlink_dir, null);
    return finishNative(src, byte, arch_nat, opt, rt, dynlink_dir, programs, null);
}

pub fn buildDebugger(
    src: *const Source,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
    host: Platform,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
) DebuggerArtifacts {
    const b = src.b;
    const m = src.manifest;

    const yacc_run = b.addRunArtifact(build_ocamlyacc);
    yacc_run.addArgs(&.{ "--strict", "-b" });
    const yacc_prefix = yacc_run.addOutputFileArg("debugger_parser");
    yacc_run.addFileArg(src.path("debugger/debugger_parser.mly"));

    const lexer: Lexer = .{ .b = b, .ocamlrun = build_ocamlrun, .exe = comp.programs.ocamllex };
    var sources = comp.sources;
    sources.gen.put(.debugger_parser_ml, yacc_prefix.dirname().path(b, "debugger_parser.ml"));
    sources.gen.put(.debugger_parser_mli, yacc_prefix.dirname().path(b, "debugger_parser.mli"));
    sources.gen.put(.debugger_lexer_ml, lexer.run(src.path("debugger/debugger_lexer.mll"), "debugger_lexer.ml"));

    const includes: []const LazyPath = &.{ comp.compiled.cmis_dir, libs.unix_dir, libs.dynlink_dir };
    const dbg = comp.ocamlc.compilePlan(m.debugger.plan, sources, .{
        .includes = includes,
        .flags = m.compiler.compflags,
    });
    const pack_wf = b.addWriteFiles();
    for (dbg.intfs.values()) |u| _ = pack_wf.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
    var pack_cmos: std.ArrayList(LazyPath) = .empty;
    for (m.debugger.packed_units) |key| {
        const name = std.fs.path.basename(key);
        const copied = pack_wf.addCopyFile(dbg.cmo(key).?, b.fmt("{s}.cmo", .{name}));
        pack_cmos.append(b.allocator, copied) catch @panic("OOM");
    }
    const packed_cmo = comp.ocamlc.link("ocamldebug.cmo", pack_cmos.items, .{
        .includes = &.{pack_wf.getDirectory()},
        .flags = &.{"-pack"},
    });

    const entry_includes: []const LazyPath = &.{ comp.compiled.cmis_dir, libs.unix_dir, libs.dynlink_dir, dbg.cmis_dir, packed_cmo.dirname() };
    const entry_intf = comp.ocamlc.intf(src.path("debugger/ocamldebug_entry.mli"), "ocamldebug_entry", .{
        .includes = entry_includes,
        .flags = m.compiler.compflags,
    });
    const entry_impl = comp.ocamlc.impl(src.path("debugger/ocamldebug_entry.ml"), "ocamldebug_entry", entry_intf.cmi, .{
        .includes = entry_includes,
        .flags = m.compiler.compflags,
    });

    const base_dbg: DebuggerArtifacts = .{
        .exe = undefined,
        .cmi = packed_cmo.dirname().path(b, "ocamldebug.cmi"),
        .parser_aux_cmi = dbg.intfs.get("debugger/parser_aux").?.cmi,
        .cmis_dir = dbg.cmis_dir,
        .packed_cmo = packed_cmo,
        .entry_cmo = entry_impl.cmo,
    };
    return relinkDebugger(src, base_dbg, comp, libs, host, null);
}

pub fn relinkDebugger(
    src: *const Source,
    base: DebuggerArtifacts,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
    host: Platform,
    host_launch_info_dir: ?LazyPath,
) DebuggerArtifacts {
    const b = src.b;
    const stublibs = b.addWriteFiles();
    if (libs.unix_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.unix_stubs.dllName(host));
    const dbg_flags: []const []const u8 = if (host.is_windows or libs.unix_stubs.shared_byt == null) &.{ "-linkall", "-no-check-prims" } else &.{"-linkall"};
    var includes: std.ArrayList(LazyPath) = .empty;
    if (host_launch_info_dir) |d| includes.append(b.allocator, d) catch @panic("OOM");
    includes.appendSlice(b.allocator, &.{ comp.compiled.cmis_dir, libs.unix_dir, libs.dynlink_dir, base.cmis_dir, base.packed_cmo.dirname(), stublibs.getDirectory() }) catch @panic("OOM");
    const exe = comp.ocamlc.link("ocamldebug", &.{
        comp.compilerlibs_dir.path(b, "ocamlcommon.cma"),
        libs.unix_dir.path(b, "unix.cma"),
        libs.dynlink_dir.path(b, "dynlink.cma"),
        comp.compiled.cmo("toplevel/genprintval").?,
        comp.compiled.cmo("toplevel/topprinters").?,
        base.packed_cmo,
        base.entry_cmo,
    }, .{
        .includes = includes.items,
        .flags = Ocamlc.concat(b, launchFlags(b, host), dbg_flags),
    });
    var out = base;
    out.exe = exe;
    return out;
}

pub fn buildOcamldocByte(
    src: *const Source,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
) OcamldocByte {
    const b = src.b;
    const m = src.manifest;

    const text_yacc = b.addRunArtifact(build_ocamlyacc);
    text_yacc.addArgs(&.{ "--strict", "-b" });
    const text_yacc_prefix = text_yacc.addOutputFileArg("odoc_text_parser");
    text_yacc.addFileArg(src.path("ocamldoc/odoc_text_parser.mly"));

    const odoc_yacc = b.addRunArtifact(build_ocamlyacc);
    odoc_yacc.addArgs(&.{ "--strict", "-b" });
    const odoc_yacc_prefix = odoc_yacc.addOutputFileArg("odoc_parser");
    odoc_yacc.addFileArg(src.path("ocamldoc/odoc_parser.mly"));

    const lexer: Lexer = .{ .b = b, .ocamlrun = build_ocamlrun, .exe = comp.programs.ocamllex };
    var sources = comp.sources;
    sources.gen.put(.odoc_text_parser_ml, text_yacc_prefix.dirname().path(b, "odoc_text_parser.ml"));
    sources.gen.put(.odoc_text_parser_mli, text_yacc_prefix.dirname().path(b, "odoc_text_parser.mli"));
    sources.gen.put(.odoc_parser_ml, odoc_yacc_prefix.dirname().path(b, "odoc_parser.ml"));
    sources.gen.put(.odoc_parser_mli, odoc_yacc_prefix.dirname().path(b, "odoc_parser.mli"));
    sources.gen.put(.odoc_text_lexer_ml, lexer.run(src.path("ocamldoc/odoc_text_lexer.mll"), "odoc_text_lexer.ml"));
    sources.gen.put(.odoc_lexer_ml, lexer.run(src.path("ocamldoc/odoc_lexer.mll"), "odoc_lexer.ml"));
    sources.gen.put(.odoc_see_lexer_ml, lexer.run(src.path("ocamldoc/odoc_see_lexer.mll"), "odoc_see_lexer.ml"));
    sources.gen.put(.odoc_ocamlhtml_ml, lexer.run(src.path("ocamldoc/odoc_ocamlhtml.mll"), "odoc_ocamlhtml.ml"));

    const byte_includes: []const LazyPath = &.{ comp.compiled.cmis_dir, libs.unix_dir, libs.str_dir, libs.dynlink_dir };
    const odoc_byte = comp.ocamlc.compilePlan(m.ocamldoc.plan, sources, .{
        .includes = byte_includes,
        .flags = m.compiler.compflags,
    });
    const odoc_info_cma = comp.ocamlc.archive("odoc_info.cma", odoc_byte.cmos(b, m.ocamldoc.odoc_info), .{});

    const lib_wf = b.addWriteFiles();
    _ = lib_wf.add("META", src.renderMeta("ocamldoc/META.in", &.{}));
    _ = lib_wf.addCopyFile(src.path("ocamldoc/ocamldoc.hva"), "ocamldoc.hva");
    _ = lib_wf.addCopyFile(odoc_info_cma, "odoc_info.cma");
    _ = lib_wf.addCopyFile(odoc_byte.cmo("ocamldoc/odoc_test").?, "odoc_test.cmo");
    for (odoc_byte.intfs.values()) |u| {
        if (std.mem.eql(u8, u.unit.name, "odoc_test")) continue;
        _ = lib_wf.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        if (u.unit.dest == .lib) {
            if (u.cmti) |cmti| _ = lib_wf.addCopyFile(cmti, b.fmt("{s}.cmti", .{u.unit.name}));
            _ = lib_wf.addCopyFile(u.src, b.fmt("{s}.mli", .{u.unit.name}));
        }
    }
    for (odoc_byte.impls.values()) |u| {
        if (u.unit.dest == .lib) {
            _ = lib_wf.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name}));
        }
    }

    return .{
        .sources = sources,
        .compiled = odoc_byte,
        .byte_lib_dir = lib_wf.getDirectory(),
        .odoc_info_cma = odoc_info_cma,
        .prog_cmos = odoc_byte.cmos(b, m.ocamldoc.ocamldoc),
    };
}

pub fn buildOcamldocNative(
    src: *const Source,
    odoc_byte: OcamldocByte,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
) OcamldocNative {
    const b = src.b;
    const m = src.manifest;
    const nat_includes: []const LazyPath = &.{ comp.compiled.cmis_dir, comp.compilerlibs_dir, libs.unix_dir, libs.str_dir, libs.dynlink_dir };
    const odoc_nat = comp.ocamlopt.compilePlan(m.ocamldoc.plan, odoc_byte.sources, odoc_byte.compiled, .{
        .includes = nat_includes,
        .flags = m.compiler.compflags,
    });
    const odoc_info_nat = comp.ocamlopt.archive("odoc_info", odoc_nat.cmxs(b, m.ocamldoc.odoc_info), .{});
    const lib_wf = b.addWriteFiles();
    _ = lib_wf.addCopyDirectory(odoc_byte.byte_lib_dir, "", .{});
    _ = lib_wf.addCopyFile(odoc_info_nat.cmxa, "odoc_info.cmxa");
    _ = lib_wf.addCopyFile(odoc_info_nat.lib, "odoc_info.a");
    for (odoc_nat.impls.values()) |u| {
        if (std.mem.eql(u8, u.unit.name, "odoc_test")) continue;
        _ = lib_wf.addCopyFile(u.impl.cmx, b.fmt("{s}.cmx", .{u.unit.name}));
    }
    return .{
        .lib_dir = lib_wf.getDirectory(),
        .nat_dir = odoc_nat.dir,
        .odoc_info_cmxa = odoc_info_nat.cmxa,
        .prog_cmxs = odoc_nat.cmxs(b, m.ocamldoc.ocamldoc),
    };
}

pub fn linkOcamldoc(
    src: *const Source,
    odoc_byte: OcamldocByte,
    odoc_nat: ?OcamldocNative,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
    rt: runtime.Artifacts,
    host: Platform,
    host_launch_info_dir: ?LazyPath,
) OcamldocArtifacts {
    const b = src.b;
    var opt_exe: ?LazyPath = null;
    if (odoc_nat) |nat| {
        const runtime_dir = b.addWriteFiles();
        _ = runtime_dir.addCopyFile(rt.libasmrun.?.getEmittedBin(), "libasmrun.a");
        _ = runtime_dir.addCopyFile(rt.libcomprmarsh.getEmittedBin(), "libcomprmarsh.a");
        _ = runtime_dir.addCopyFile(rt.zstd_lib.getEmittedBin(), "libzstd.a");
        _ = runtime_dir.addCopyFile(libs.unix_stubs.static_nat.getEmittedBin(), "libunixnat.a");
        _ = runtime_dir.addCopyFile(libs.str_stubs.static_nat.getEmittedBin(), "libcamlstrnat.a");

        var nat_objs: std.ArrayList(LazyPath) = .empty;
        nat_objs.appendSlice(b.allocator, &.{
            comp.compilerlibs_dir.path(b, "ocamlcommon.cmxa"),
            libs.unix_dir.path(b, "unix.cmxa"),
            libs.str_dir.path(b, "str.cmxa"),
            libs.dynlink_dir.path(b, "dynlink.cmxa"),
            nat.odoc_info_cmxa,
        }) catch @panic("OOM");
        nat_objs.appendSlice(b.allocator, nat.prog_cmxs) catch @panic("OOM");

        opt_exe = comp.ocamlopt.link("ocamldoc.opt", nat_objs.items, .{
            .includes = &.{ comp.compiled.cmis_dir, comp.compilerlibs_dir, runtime_dir.getDirectory(), libs.unix_dir, libs.str_dir, libs.dynlink_dir, nat.nat_dir },
            .flags = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin },
            .strip_debug = true,
        });
    }

    const base_odoc: OcamldocArtifacts = .{
        .byte = undefined,
        .opt = opt_exe,
        .lib_dir = if (odoc_nat) |nat| nat.lib_dir else odoc_byte.byte_lib_dir,
        .cmis_dir = odoc_byte.compiled.cmis_dir,
        .odoc_info_cma = odoc_byte.odoc_info_cma,
        .prog_cmos = odoc_byte.prog_cmos,
    };
    return relinkOcamldoc(src, base_odoc, comp, libs, rt, host, host_launch_info_dir);
}

pub fn buildOcamldoc(
    src: *const Source,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
    rt: runtime.Artifacts,
    host: Platform,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
) OcamldocArtifacts {
    const odoc_byte = buildOcamldocByte(src, comp, libs, build_ocamlrun, build_ocamlyacc);
    const odoc_nat = if (rt.platform.hasNativeCompiler()) buildOcamldocNative(src, odoc_byte, comp, libs) else null;
    return linkOcamldoc(src, odoc_byte, odoc_nat, comp, libs, rt, host, null);
}

pub fn relinkOcamldoc(
    src: *const Source,
    base: OcamldocArtifacts,
    comp: Artifacts,
    libs: otherlibs.Artifacts,
    rt: runtime.Artifacts,
    host: Platform,
    host_launch_info_dir: ?LazyPath,
) OcamldocArtifacts {
    const b = src.b;
    var byte_objs: std.ArrayList(LazyPath) = .empty;
    byte_objs.appendSlice(b.allocator, &.{
        comp.compilerlibs_dir.path(b, "ocamlcommon.cma"),
        libs.unix_dir.path(b, "unix.cma"),
        libs.str_dir.path(b, "str.cma"),
        libs.dynlink_dir.path(b, "dynlink.cma"),
        base.odoc_info_cma,
    }) catch @panic("OOM");
    byte_objs.appendSlice(b.allocator, base.prog_cmos) catch @panic("OOM");

    const stublibs = b.addWriteFiles();
    if (libs.unix_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.unix_stubs.dllName(rt.platform));
    if (libs.str_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.str_stubs.dllName(rt.platform));
    const odoc_flags = if (host.is_windows or libs.unix_stubs.shared_byt == null)
        Ocamlc.concat(b, launchFlags(b, host), &.{"-no-check-prims"})
    else
        launchFlags(b, host);
    var includes: std.ArrayList(LazyPath) = .empty;
    if (host_launch_info_dir) |d| includes.append(b.allocator, d) catch @panic("OOM");
    includes.appendSlice(b.allocator, &.{ base.cmis_dir, stublibs.getDirectory() }) catch @panic("OOM");
    const byte_exe = comp.ocamlc.link("ocamldoc.byte", byte_objs.items, .{
        .includes = includes.items,
        .flags = odoc_flags,
    });
    var out = base;
    out.byte = byte_exe;
    return out;
}

const Lexer = struct {
    b: *std.Build,
    ocamlrun: *std.Build.Step.Compile,
    exe: LazyPath,

    fn run(self: Lexer, mll: LazyPath, out_name: []const u8) LazyPath {
        const r = self.b.addRunArtifact(self.ocamlrun);
        r.addFileArg(self.exe);
        r.addArgs(&.{ "-q", "-o" });
        const out = r.addOutputFileArg(out_name);
        r.addFileArg(mll);
        return out;
    }
};

const Linker = struct {
    ocamlc: Ocamlc,
    includes: []const LazyPath,
    launch_flags: []const []const u8,

    fn link(self: Linker, name: []const u8, objs: []const LazyPath, flags: []const []const u8) LazyPath {
        return self.ocamlc.link(name, objs, .{
            .includes = self.includes,
            .flags = Ocamlc.concat(self.ocamlc.b, self.launch_flags, flags),
        });
    }
};

/// How installed bytecode programs find `ocamlrun` and the stdlib. Relocatable
/// releases are linked so nothing depends on the install prefix: the stdlib is
/// `../lib/ocaml` relative to `ocamlrun`, and the launcher looks for `ocamlrun`
/// next to the program, then on `PATH`.
fn launchFlags(b: *std.Build, host: Platform) []const []const u8 {
    return b.allocator.dupe([]const u8, &.{
        "-set-runtime-default",
        "standard_library_default=" ++ stdlib_dir_from_bin,
        "-launch-method",
        if (host.is_windows) "exe" else "sh",
        "-runtime-search",
        "enable",
    }) catch @panic("OOM");
}

/// Compile and link a single-file helper run at build time (`ocamlrun tool.byte`).
fn buildTool(boot: Ocamlc, src_ml: LazyPath, name: []const u8, launch_info_dir: LazyPath) LazyPath {
    const compiled = boot.impl(src_ml, name, null, .{});
    return boot.link(boot.b.fmt("{s}.byte", .{name}), &.{compiled.cmo}, .{ .includes = &.{launch_info_dir} });
}

fn runCapture(
    b: *std.Build,
    ocamlrun: *std.Build.Step.Compile,
    exe: LazyPath,
    args: []const []const u8,
    stdin: LazyPath,
) LazyPath {
    const run = b.addRunArtifact(ocamlrun);
    run.addFileArg(exe);
    run.addArgs(args);
    run.setStdIn(.{ .lazy_path = stdin });
    return run.captureStdOut(.{});
}

fn renderConfigCommon(src: Source) []const u8 {
    const mn = src.manifest.version.magic.numbers;
    return src.renderAt("utils/config.common.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from utils/config.common.ml.in" },
        .{ .name = "EXEC_MAGIC_NUMBER", .value = mn.exec },
        .{ .name = "CMI_MAGIC_NUMBER", .value = mn.cmi },
        .{ .name = "CMO_MAGIC_NUMBER", .value = mn.cmo },
        .{ .name = "CMA_MAGIC_NUMBER", .value = mn.cma },
        .{ .name = "CMX_MAGIC_NUMBER", .value = mn.cmx_clambda },
        .{ .name = "CMXA_MAGIC_NUMBER", .value = mn.cmxa_clambda },
        .{ .name = "AST_IMPL_MAGIC_NUMBER", .value = mn.ast_impl },
        .{ .name = "AST_INTF_MAGIC_NUMBER", .value = mn.ast_intf },
        .{ .name = "CMXS_MAGIC_NUMBER", .value = mn.cmxs },
        .{ .name = "CMT_MAGIC_NUMBER", .value = mn.cmt },
        .{ .name = "LINEAR_MAGIC_NUMBER", .value = mn.linear },
    });
}

/// `Config` values that `configure` would produce for `host` -> `target`.
fn renderConfigGenerated(src: Source, host: Platform, target: Platform) []const u8 {
    const b = src.b;
    const c = target.c;

    // Relocatable releases resolve these at runtime: `bindir` from the relative
    // stdlib, `target_bindir = "."` as the directory of the running compiler.
    const bindir = ".";

    const cflags = c.cflagsString(b);
    const cppflags = c.cppflagsString(b);
    const cclibs = c.libsString(b);
    const rpath = if (target.is_elf) "-Wl,-rpath," else "";
    const native_ldflags = "";
    // Zig on PATH keeps installed compilers relocatable, without system cross-gcc.
    const triple = target.resolved.result.zigTriple(b.allocator) catch @panic("OOM");
    const cc = b.fmt("zig cc -target {s} -fno-sanitize=undefined{s}", .{ triple, if (target.resolved.result.abi.isMusl()) " -dynamic" else "" });
    const asm_cmd = b.fmt("{s}{s} -Wno-trigraphs -fdebug-compilation-dir=. -c", .{ cc, if (target.arch == .riscv) " -mcpu=baseline_rv64-c-zca-zcd" else "" });
    const packld = b.fmt("{s} -nostdlib -r -o ", .{cc});
    const mkdll = b.fmt("{s} -shared{s}", .{ cc, if (target.is_macos) " -undefined dynamic_lookup -Wl,-w" else "" });
    const mkexe = b.fmt("{s} {s}{s}", .{ cc, cflags, if (target.is_elf) " -Wl,-E" else if (target.is_windows) " -municode" else "" });
    const so_ext = target.dllExt();
    const bool_str = struct {
        fn f(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.f;

    const runtime_id = target.runtimeId(b, src.manifest.version);
    return src.renderAt("utils/config.generated.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from utils/config.generated.ml.in" },
        .{ .name = "QS", .value = "" },
        .{ .name = "ocaml_bindir", .value = bindir },
        .{ .name = "TARGET_BINDIR", .value = bindir },
        .{ .name = "ccomp_type", .value = "cc" },
        .{ .name = "CC", .value = cc },
        .{ .name = "ocaml_cc_vendor", .value = "clang-19" },
        .{ .name = "outputobj", .value = "-o " },
        .{ .name = "cc_has_debug_prefix_map", .value = "true" },
        .{ .name = "ocaml_cv_prog_as_debug_prefix_map", .value = "false" },
        .{ .name = "as_is_cc", .value = "true" },
        .{ .name = "bytecode_cflags", .value = cflags },
        .{ .name = "bytecode_cppflags", .value = cppflags },
        .{ .name = "native_cflags", .value = cflags },
        .{ .name = "native_cppflags", .value = cppflags },
        .{ .name = "zstd_libs", .value = "-lzstd" },
        .{ .name = "cclibs", .value = cclibs },
        .{ .name = "native_ldflags", .value = native_ldflags },
        .{ .name = "with_nonexecstack_note", .value = bool_str(target.is_linux and target.is_elf) },
        .{ .name = "PACKLD", .value = packld },
        .{ .name = "rpath", .value = rpath },
        .{ .name = "mksharedlibrpath", .value = rpath },
        .{ .name = "AR", .value = "zig ar" },
        .{ .name = "supports_shared_libraries", .value = bool_str(!target.is_windows) },
        .{ .name = "natdynlink", .value = bool_str(!target.is_windows and target.hasNativeCompiler()) },
        .{ .name = "mkdll_exp", .value = mkdll },
        .{ .name = "mkexe_exp", .value = mkexe },
        .{ .name = "mkmaindll_exp", .value = mkdll },
        .{ .name = "flambda", .value = "false" },
        .{ .name = "flambda_invariants", .value = "false" },
        .{ .name = "cmm_invariants", .value = "false" },
        .{ .name = "codegen_invariants", .value = "false" },
        .{ .name = "windows_unicode", .value = if (target.is_windows) "1" else "0" },
        .{ .name = "flat_float_array", .value = "true" },
        .{ .name = "align_double", .value = bool_str(!target.arch64) },
        .{ .name = "align_int64", .value = bool_str(!target.arch64) },
        .{ .name = "function_sections", .value = bool_str(target.is_elf) },
        .{ .name = "afl", .value = "false" },
        .{ .name = "bytecode_runtime_id", .value = runtime_id },
        .{ .name = "native_runtime_id", .value = runtime_id },
        .{ .name = "native_compiler", .value = bool_str(target.hasNativeCompiler()) },
        .{ .name = "arch", .value = target.archName() },
        .{ .name = "model", .value = target.model },
        .{ .name = "system", .value = target.system },
        .{ .name = "target_os_type", .value = target.osType() },
        .{ .name = "AS", .value = asm_cmd },
        .{ .name = "asm_cfi_supported", .value = bool_str(!target.is_windows) },
        .{ .name = "asm_size_type_directives", .value = bool_str(target.is_elf) },
        .{ .name = "asm_dwarf_version", .value = "None" },
        .{ .name = "frame_pointers", .value = "false" },
        .{ .name = "reserved_header_bits", .value = "0" },
        .{ .name = "EXEEXT", .value = target.exeExt() },
        .{ .name = "OBJEXT", .value = "o" },
        .{ .name = "S", .value = "s" },
        .{ .name = "libext", .value = "a" },
        .{ .name = "SO", .value = so_ext },
        .{ .name = "host", .value = host.triplet },
        .{ .name = "target", .value = target.triplet },
        .{ .name = "systhread_support", .value = "true" },
        .{ .name = "flexdll_dir", .value = "" },
        .{ .name = "ar_supports_response_files", .value = "true" },
        .{ .name = "tsan", .value = "false" },
        .{ .name = "shebangscripts", .value = bool_str(!host.is_windows) },
        .{ .name = "suffixing", .value = "false" },
        .{ .name = "launch_method_target", .value = if (target.is_windows) "exe" else "sh" },
        .{ .name = "runtime_search_target", .value = "fallback" },
    });
}
