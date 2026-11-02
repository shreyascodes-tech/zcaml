//! Bootstrap bytecode compilers and tools, followed by native `compiler-libs`
//! and host-native `.opt` executables.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const driver = @import("driver.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const runtime = @import("runtime.zig");
const configure = @import("configure.zig");
const Tools = @import("tools.zig");
const LazyPath = std.Build.LazyPath;

pub const Artifacts = struct {
    /// Bytecode executables, to be run by the host `ocamlrun`.
    programs: Programs,
    compilerlibs_dir: LazyPath,
    profiling_dir: LazyPath,
    native_programs: ?NativePrograms = null,
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

pub const ByteCommon = struct {
    config_main_ml: LazyPath,
    config_cmt: LazyPath,
    ocamlcommon_cma: LazyPath,
    byte_compilerlibs_dir: LazyPath,
    compiled: Ocamlc.Compiled,
    ocamlc_byte: LazyPath,
    ocamlopt_byte: LazyPath,
};

pub const NativeCommon = struct {
    config_cmx: LazyPath,
    config_obj: LazyPath,
    cmxa: LazyPath,
    lib: LazyPath,
    ocamlopt_opt: LazyPath,
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
    frontend_byte: Ocamlc.Compiled,
    ocamlbytecomp_cma: LazyPath,
    ocamlmiddleend_cma: LazyPath,
    ocamltoplevel_cma: LazyPath,
    profiling_dir: LazyPath,
};

/// Architecture-dependent bytecode compiler artifacts (`boot/ocamlc` output), built once per `Arch`.
pub const ArchByte = struct {
    arch: ?Platform.Arch,
    sources: Source.Resolver,
    compiled: Ocamlc.Compiled,
    base_compilerlibs_dir: LazyPath,
    ocamloptcomp_cma: LazyPath,
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
    ocamllex_opt: ?LazyPath = null,
};

/// Default stdlib location, relative to `bin/`.
pub const stdlib_dir_from_bin = "../lib/ocaml";

pub fn buildShared(
    src: *const Source,
    stdlib_base_dir: LazyPath,
    build_launch_info_dir: LazyPath,
    rt_common: runtime.Common,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
) Shared {
    const b = src.b;
    const m = src.manifest;

    const config_common = configure.compilerConfigCommon(src.*);
    const config_wf = b.addWriteFiles();
    const compilerlibs_meta = config_wf.add("META", src.renderMeta("compilerlibs/META.in", &.{}));

    const gen, _ = Tools.run(b, .gen_compiler_sources, .{
        .ocaml_src_dir = .of(src.path("")),
        .primitives = .of(rt_common.primitives),
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
        .primitives = rt_common.primitives,
        .prefix_map = src.prefixMap(),
        .cwd = src.path(""),
    };
    const cvt_emit = buildTool(boot, lexer.run(src.path("tools/cvt_emit.mll"), "cvt_emit.ml"), "cvt_emit", build_launch_info_dir);

    const dbg_yacc = b.addRunArtifact(build_ocamlyacc);
    dbg_yacc.addArgs(&.{ "--strict", "-b" });
    const dbg_yacc_prefix = dbg_yacc.addOutputFileArg("debugger_parser");
    dbg_yacc.addFileArg(src.path("debugger/debugger_parser.mly"));

    const text_yacc = b.addRunArtifact(build_ocamlyacc);
    text_yacc.addArgs(&.{ "--strict", "-b" });
    const text_yacc_prefix = text_yacc.addOutputFileArg("odoc_text_parser");
    text_yacc.addFileArg(src.path("ocamldoc/odoc_text_parser.mly"));

    const odoc_yacc = b.addRunArtifact(build_ocamlyacc);
    odoc_yacc.addArgs(&.{ "--strict", "-b" });
    const odoc_yacc_prefix = odoc_yacc.addOutputFileArg("odoc_parser");
    odoc_yacc.addFileArg(src.path("ocamldoc/odoc_parser.mly"));

    var base_sources: Source.Resolver = .{ .source = src, .arch = null };
    base_sources.gen.put(.domainstate_ml, gen.domainstate_ml.lazyPath());
    base_sources.gen.put(.domainstate_mli, gen.domainstate_mli.lazyPath());
    base_sources.gen.put(.runtimedef_ml, gen.runtimedef_ml.lazyPath());
    base_sources.gen.put(.camlinternalMenhirLib_mli, gen.menhir_lib_mli.lazyPath());
    base_sources.gen.put(.parser_ml, gen.parser_ml.lazyPath());
    base_sources.gen.put(.parser_mli, gen.parser_mli.lazyPath());
    base_sources.gen.put(.parsing_lexer_ml, lexer.run(src.path("parsing/lexer.mll"), "lexer.ml"));
    base_sources.gen.put(.byterntm_ml, lexer.run(src.path("bytecomp/byterntm.mll"), "byterntm.ml"));
    base_sources.gen.put(.opcodes_ml, rt_common.opcodes_ml);
    base_sources.gen.put(.opcodes_mli, rt_common.opcodes_mli);
    base_sources.gen.put(.opnames_ml, rt_common.opnames_ml);
    base_sources.gen.put(.lex_parser_ml, yacc_prefix.dirname().path(b, "parser.ml"));
    base_sources.gen.put(.lex_parser_mli, yacc_prefix.dirname().path(b, "parser.mli"));
    base_sources.gen.put(.lex_lexer_ml, lexer.run(src.path("lex/lexer.mll"), "lexer.ml"));
    base_sources.gen.put(.debugger_parser_ml, dbg_yacc_prefix.dirname().path(b, "debugger_parser.ml"));
    base_sources.gen.put(.debugger_parser_mli, dbg_yacc_prefix.dirname().path(b, "debugger_parser.mli"));
    base_sources.gen.put(.debugger_lexer_ml, lexer.run(src.path("debugger/debugger_lexer.mll"), "debugger_lexer.ml"));
    base_sources.gen.put(.odoc_text_parser_ml, text_yacc_prefix.dirname().path(b, "odoc_text_parser.ml"));
    base_sources.gen.put(.odoc_text_parser_mli, text_yacc_prefix.dirname().path(b, "odoc_text_parser.mli"));
    base_sources.gen.put(.odoc_parser_ml, odoc_yacc_prefix.dirname().path(b, "odoc_parser.ml"));
    base_sources.gen.put(.odoc_parser_mli, odoc_yacc_prefix.dirname().path(b, "odoc_parser.mli"));
    base_sources.gen.put(.odoc_text_lexer_ml, lexer.run(src.path("ocamldoc/odoc_text_lexer.mll"), "odoc_text_lexer.ml"));
    base_sources.gen.put(.odoc_lexer_ml, lexer.run(src.path("ocamldoc/odoc_lexer.mll"), "odoc_lexer.ml"));
    base_sources.gen.put(.odoc_see_lexer_ml, lexer.run(src.path("ocamldoc/odoc_see_lexer.mll"), "odoc_see_lexer.ml"));
    base_sources.gen.put(.odoc_ocamlhtml_ml, lexer.run(src.path("ocamldoc/odoc_ocamlhtml.mll"), "odoc_ocamlhtml.ml"));

    const lex = boot.compilePlan(m.lex.plan, base_sources, .{ .flags = m.compiler.compflags });

    const frontend_byte = boot.compilePlan(m.compiler.plan, base_sources, .{
        .flags = m.compiler.compflags,
        .only_frontend = true,
    });

    const ocamlbytecomp_cma = boot.archive("ocamlbytecomp.cma", frontend_byte.cmos(b, m.compiler.ocamlbytecomp), .{});
    const ocamlmiddleend_cma = boot.archive("ocamlmiddleend.cma", frontend_byte.cmos(b, m.compiler.ocamlmiddleend), .{});
    const ocamltoplevel_cma = boot.archive("ocamltoplevel.cma", frontend_byte.cmos(b, m.compiler.ocamltoplevel), .{});

    const profiling = b.addWriteFiles();
    for (frontend_byte.intfs.values()) |u| {
        if (u.unit.dest == .profiling) {
            _ = profiling.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
            if (u.cmti) |cmti| _ = profiling.addCopyFile(cmti, b.fmt("{s}.cmti", .{u.unit.name}));
        }
    }
    for (frontend_byte.impls.values()) |u| {
        if (u.unit.dest == .profiling) {
            _ = profiling.addCopyFile(u.impl.cmo, b.fmt("{s}.cmo", .{u.unit.name}));
            _ = profiling.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name}));
        }
    }

    return .{
        .config_common = config_common,
        .compilerlibs_meta = compilerlibs_meta,
        .base_sources = base_sources,
        .cvt_emit = cvt_emit,
        .boot = boot,
        .lex = lex,
        .build_ocamlrun = build_ocamlrun,
        .frontend_byte = frontend_byte,
        .ocamlbytecomp_cma = ocamlbytecomp_cma,
        .ocamlmiddleend_cma = ocamlmiddleend_cma,
        .ocamltoplevel_cma = ocamltoplevel_cma,
        .profiling_dir = profiling.getDirectory(),
    };
}

pub fn buildArchByte(src: *const Source, shared: Shared, arch: ?Platform.Arch) ArchByte {
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
        .reuse_frontend = shared.frontend_byte,
    });

    const compilerlibs = b.addWriteFiles();
    _ = compilerlibs.addCopyFile(shared.compilerlibs_meta, "META");

    for (compiled.intfs.values()) |u| {
        if (u.unit.dest != .lib) continue;
        _ = compilerlibs.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        if (u.cmti) |cmti| {
            _ = compilerlibs.addCopyFile(cmti, b.fmt("{s}.cmti", .{u.unit.name}));
            _ = compilerlibs.addCopyFile(u.src, b.fmt("{s}.mli", .{u.unit.name}));
        }
    }
    for (compiled.impls.values()) |u| {
        if (u.unit.dest == .lib) {
            _ = compilerlibs.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name}));
        }
    }
    for ([_][]const u8{ "driver/main", "driver/optmain", "toplevel/topstart" }) |key| {
        _ = compilerlibs.addCopyFile(compiled.cmo(key).?, b.fmt("{s}.cmo", .{std.fs.path.basename(key)}));
    }

    _ = compilerlibs.addCopyFile(shared.ocamlbytecomp_cma, "ocamlbytecomp.cma");
    _ = compilerlibs.addCopyFile(shared.ocamlmiddleend_cma, "ocamlmiddleend.cma");
    _ = compilerlibs.addCopyFile(shared.ocamltoplevel_cma, "ocamltoplevel.cma");

    const ocamloptcomp = shared.boot.archive("ocamloptcomp.cma", compiled.cmos(b, cc.ocamloptcomp), .{});
    _ = compilerlibs.addCopyFile(ocamloptcomp, "ocamloptcomp.cma");

    return .{
        .arch = arch,
        .sources = sources,
        .compiled = compiled,
        .base_compilerlibs_dir = compilerlibs.getDirectory(),
        .ocamloptcomp_cma = ocamloptcomp,
    };
}

pub fn buildByteCommon(
    src: *const Source,
    shared: Shared,
    arch_byte: ArchByte,
    host: Platform,
    target: Platform,
    host_launch_info_dir: LazyPath,
) ByteCommon {
    const b = src.b;
    const cc = src.manifest.compiler;
    const boot = shared.boot;

    const config_wf = b.addWriteFiles();
    const config_main_ml = config_wf.add("config_main.ml", configure.compilerConfigMl(src.*, shared.config_common, host, target));

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

    const launch_flags = launchFlags(b, host);
    const linker: Linker = .{
        .ocamlc = boot,
        .includes = &.{ compiled.cmis_dir, host_launch_info_dir },
        .launch_flags = launch_flags,
    };
    const ocamlc_byte = linker.link("ocamlc.byte", &.{ ocamlcommon, shared.ocamlbytecomp_cma, compiled.cmo("driver/main").? }, &.{ "-compat-32", "-g" });
    const ocamlopt_byte = linker.link("ocamlopt.byte", &.{ ocamlcommon, arch_byte.ocamloptcomp_cma, compiled.cmo("driver/optmain").? }, &.{"-g"});

    return .{
        .config_main_ml = config_main_ml,
        .config_cmt = cfg_impl.cmt,
        .ocamlcommon_cma = ocamlcommon,
        .byte_compilerlibs_dir = compilerlibs.getDirectory(),
        .compiled = compiled,
        .ocamlc_byte = ocamlc_byte,
        .ocamlopt_byte = ocamlopt_byte,
    };
}

pub fn buildBytePrograms(
    src: *const Source,
    shared: Shared,
    byte_common: ByteCommon,
    host: Platform,
    host_launch_info_dir: LazyPath,
) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const cc = m.compiler;
    const boot = shared.boot;

    const compiled = byte_common.compiled;
    const ocamlcommon = byte_common.ocamlcommon_cma;
    const ocamlbytecomp = shared.ocamlbytecomp_cma;
    const ocamlmiddleend = shared.ocamlmiddleend_cma;
    const ocamltoplevel = shared.ocamltoplevel_cma;

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
        .ocamlc = byte_common.ocamlc_byte,
        .ocamlc_stripped = stripByteProg(b, shared.build_ocamlrun, stripdebug, byte_common.ocamlc_byte, "ocamlc.byte.stripped"),
        .ocamlopt = byte_common.ocamlopt_byte,
        .ocamlopt_stripped = stripByteProg(b, shared.build_ocamlrun, stripdebug, byte_common.ocamlopt_byte, "ocamlopt.byte.stripped"),
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

    return .{
        .programs = programs,
        .compilerlibs_dir = byte_common.byte_compilerlibs_dir,
        .profiling_dir = shared.profiling_dir,
    };
}

pub fn buildArchNative(
    src: *const Source,
    shared: Shared,
    arch_byte: ArchByte,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
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

    const ocamllex_opt: ?LazyPath = if (dynlink_dir != null) blk: {
        const lex = opt.compilePlan(src.manifest.lex.plan, arch_byte.sources, shared.lex, .{ .flags = cc.compflags });
        const runtime_dir = nativeRuntimeDir(b, rt);
        const std_flags: []const []const u8 = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin };
        break :blk opt.link("ocamllex.opt", lex.cmxs(b, src.manifest.lex.ocamllex), .{
            .includes = &.{ arch_byte.compiled.cmis_dir, runtime_dir, lex.dir },
            .flags = std_flags,
            .strip_debug = true,
        });
    } else null;

    return .{
        .compiled = compiled,
        .bytecomp_cmxa = bytecomp,
        .middleend_cmxa = middleend,
        .optcomp_cmxa = optcomp,
        .toplevel_cmxa = toplevel,
        .base_libs_dir = if (libs) |l| l.getDirectory() else null,
        .profiling_dir = if (profiling) |p| p.getDirectory() else null,
        .ocamllex_opt = ocamllex_opt,
    };
}

pub fn buildNativeCommon(
    src: *const Source,
    arch_byte: ArchByte,
    arch_nat: ArchNative,
    config_main_ml: LazyPath,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
) NativeCommon {
    const b = src.b;
    const cc = src.manifest.compiler;
    const cfg_intf = arch_byte.compiled.intfs.get("utils/config").?;
    const cfg_nat = opt.impl(config_main_ml, "config", cfg_intf.cmi, .{
        .includes = &.{arch_byte.compiled.cmis_dir},
        .flags = cc.compflags,
    });

    var compiled = arch_nat.compiled;
    compiled.impls = arch_nat.compiled.impls.clone(b.allocator) catch @panic("OOM");
    compiled.impls.put(b.allocator, "utils/config", .{ .unit = cfg_intf.unit, .impl = cfg_nat }) catch @panic("OOM");

    const common_archive = opt.archive("ocamlcommon", compiled.cmxs(b, cc.ocamlcommon), .{
        .flags = &.{ "-linkall", "-cclib", "-lcomprmarsh", "-cclib", "-lzstd" },
    });

    const runtime_dir = nativeRuntimeDir(b, rt);
    const std_flags: []const []const u8 = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin };
    const link_opts: Ocamlopt.Options = .{
        .includes = &.{ arch_byte.compiled.cmis_dir, arch_nat.compiled.dir, runtime_dir },
        .flags = std_flags,
        .strip_debug = true,
    };
    const ocamlopt_opt = opt.link("ocamlopt.opt", &.{ common_archive.cmxa, arch_nat.optcomp_cmxa, arch_nat.compiled.impls.get("driver/optmain").?.impl.cmx }, link_opts);

    return .{
        .config_cmx = cfg_nat.cmx,
        .config_obj = cfg_nat.obj,
        .cmxa = common_archive.cmxa,
        .lib = common_archive.lib,
        .ocamlopt_opt = ocamlopt_opt,
    };
}

pub const NativeCompilerLibs = struct {
    compilerlibs_dir: LazyPath,
    profiling_dir: LazyPath,
};

pub fn assembleNativeCompilerLibs(
    b: *std.Build,
    byte_common: ByteCommon,
    profiling_dir: LazyPath,
    arch_nat: ArchNative,
    nat_common: NativeCommon,
) NativeCompilerLibs {
    const libs = b.addWriteFiles();
    _ = libs.addCopyDirectory(byte_common.byte_compilerlibs_dir, "", .{});
    if (arch_nat.base_libs_dir) |base_l| {
        _ = libs.addCopyDirectory(base_l, "", .{});
    }
    _ = libs.addCopyFile(nat_common.config_cmx, "config.cmx");
    _ = libs.addCopyFile(nat_common.config_obj, "config.o");
    _ = libs.addCopyFile(nat_common.cmxa, "ocamlcommon.cmxa");
    _ = libs.addCopyFile(nat_common.lib, "ocamlcommon.a");

    const prof = b.addWriteFiles();
    _ = prof.addCopyDirectory(profiling_dir, "", .{});
    if (arch_nat.profiling_dir) |p| {
        _ = prof.addCopyDirectory(p, "", .{});
    }

    return .{
        .compilerlibs_dir = libs.getDirectory(),
        .profiling_dir = prof.getDirectory(),
    };
}

pub fn nativeRuntimeDir(b: *std.Build, rt: runtime.Artifacts) LazyPath {
    const runtime_dir = b.addWriteFiles();
    _ = runtime_dir.addCopyFile(rt.libasmrun.?.getEmittedBin(), "libasmrun.a");
    _ = runtime_dir.addCopyFile(rt.libcomprmarsh.getEmittedBin(), "libcomprmarsh.a");
    _ = runtime_dir.addCopyFile(rt.zstd_lib.getEmittedBin(), "libzstd.a");
    return runtime_dir.getDirectory();
}

pub fn linkNativePrograms(
    b: *std.Build,
    arch_byte: ArchByte,
    arch_nat: ArchNative,
    nat_common: NativeCommon,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
    ocamlopt_opt: LazyPath,
    ocamllex_opt: LazyPath,
) NativePrograms {
    const runtime_dir = nativeRuntimeDir(b, rt);

    const std_flags: []const []const u8 = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin };
    const opts: Ocamlopt.Options = .{
        .includes = &.{ arch_byte.compiled.cmis_dir, arch_nat.compiled.dir, runtime_dir },
        .flags = std_flags,
        .strip_debug = true,
    };
    return .{
        .ocamlc = opt.link("ocamlc.opt", &.{ nat_common.cmxa, arch_nat.bytecomp_cmxa, arch_nat.compiled.impls.get("driver/main").?.impl.cmx }, opts),
        .ocamlopt = ocamlopt_opt,
        .ocamllex = ocamllex_opt,
        .ocamldep = opt.link("ocamldep.opt", &.{ nat_common.cmxa, arch_nat.bytecomp_cmxa, arch_nat.compiled.impls.get("tools/ocamldep").?.impl.cmx }, opts),
        .ocamlobjinfo = opt.link("ocamlobjinfo.opt", &.{ nat_common.cmxa, arch_nat.bytecomp_cmxa, arch_nat.middleend_cmxa, arch_nat.compiled.impls.get("tools/objinfo").?.impl.cmx }, opts),
    };
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
            .flags = driver.concat(self.ocamlc.b, self.launch_flags, flags),
        });
    }
};

/// How installed bytecode programs find `ocamlrun` and the stdlib. Relocatable
/// releases are linked so nothing depends on the install prefix: the stdlib is
/// `../lib/ocaml` relative to `ocamlrun`, and the launcher looks for `ocamlrun`
/// next to the program, then on `PATH`.
pub fn launchFlags(b: *std.Build, host: Platform) []const []const u8 {
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
