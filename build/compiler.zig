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

pub const OcamldocArtifacts = struct {
    byte: LazyPath,
    opt: ?LazyPath = null,
    lib_dir: LazyPath,
};

pub const DebuggerArtifacts = struct {
    exe: LazyPath,
    cmi: LazyPath,
    parser_aux_cmi: LazyPath,
};

pub const Options = struct {
    /// Where the compilers run.
    host: Platform,
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
};

/// Default stdlib location, relative to `bin/`.
pub const stdlib_dir_from_bin = "../lib/ocaml";

pub fn build(src: *const Source, options: Options) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const host = options.host;
    const target = options.target_rt.platform;

    // 1. utils/config_main.ml, utils/config_boot.ml, compilerlibs/META
    const config_common = renderConfigCommon(src.*);
    const config_wf = b.addWriteFiles();
    const config_main_ml = config_wf.add("config_main.ml", b.fmt("{s}\n{s}", .{ renderConfigGenerated(src.*, host, target), config_common }));
    const config_boot_ml = config_wf.add("config_boot.ml", b.fmt("{s}\n{s}", .{ src.read("utils/config.fixed.ml"), config_common }));

    // 2. domainstate, runtimedef, menhir parser
    const gen, _ = Tools.run(b, .gen_compiler_sources, .{
        .ocaml_src_dir = .of(src.path("")),
        .primitives = .of(options.target_rt.primitives),
        .arch64 = target.arch64,
        .domainstate_ml = .of("domainstate.ml"),
        .domainstate_mli = .of("domainstate.mli"),
        .runtimedef_ml = .of("runtimedef.ml"),
        .menhir_lib_mli = .of("camlinternalMenhirLib.mli"),
        .parser_ml = .of("parser.ml"),
        .parser_mli = .of("parser.mli"),
    });

    // 3. ocamlyacc / ocamllex outputs
    const yacc_run = b.addRunArtifact(options.build_ocamlyacc);
    yacc_run.addArgs(&.{ "--strict", "-b" });
    const yacc_prefix = yacc_run.addOutputFileArg("parser");
    yacc_run.addFileArg(src.path("lex/parser.mly"));

    const lexer: Lexer = .{ .b = b, .ocamlrun = options.build_ocamlrun, .exe = src.path("boot/ocamllex") };

    // 4. tools/make_opcodes and tools/cvt_emit -> opcodes.ml{,i}, opnames.ml, emit.ml
    const prefix_map = src.prefixMap();
    const boot: Ocamlc = .{
        .b = b,
        .ocamlrun = options.build_ocamlrun,
        .exe = src.path("boot/ocamlc"),
        .stdlib_dir = options.stdlib.dir,
        .primitives = options.target_rt.primitives,
        .prefix_map = prefix_map,
        .cwd = src.path(""),
    };
    const launch_flags = launchFlags(b, host);
    const make_opcodes = buildTool(boot, lexer.run(src.path("tools/make_opcodes.mll"), "make_opcodes.ml"), "make_opcodes", launch_flags);
    const cvt_emit = buildTool(boot, lexer.run(src.path("tools/cvt_emit.mll"), "cvt_emit.ml"), "cvt_emit", launch_flags);
    const instruct_h = src.path("runtime/caml/instruct.h");

    const opcodes_ml = runCapture(b, options.build_ocamlrun, make_opcodes, &.{"-opcodes"}, instruct_h);
    const opnames_ml = runCapture(b, options.build_ocamlrun, make_opcodes, &.{"-opnames"}, instruct_h);
    const opcodes_mli = blk: {
        const run = boot.cmd(.{ .flags = &.{ "-i", "-impl" } });
        run.addFileArg(opcodes_ml);
        break :blk run.captureStdOut(.{});
    };
    const emit_ml = blk: {
        const body = runCapture(b, options.build_ocamlrun, cvt_emit, &.{}, src.path(b.fmt("asmcomp/{s}/emit.mlp", .{target.archName()})));
        const prep, _ = Tools.run(b, .prepend_emit_line, .{
            .cvt_emit_output = .of(body),
            .arch = target.archName(),
            .out_emit_ml = .of("emit.ml"),
        });
        break :blk prep.out_emit_ml.lazyPath();
    };

    var sources: Source.Resolver = .{ .source = src, .arch = target.arch };
    sources.gen.put(.config_main_ml, config_main_ml);
    sources.gen.put(.config_boot_ml, config_boot_ml);
    sources.gen.put(.domainstate_ml, gen.domainstate_ml.lazyPath());
    sources.gen.put(.domainstate_mli, gen.domainstate_mli.lazyPath());
    sources.gen.put(.runtimedef_ml, gen.runtimedef_ml.lazyPath());
    sources.gen.put(.camlinternalMenhirLib_mli, gen.menhir_lib_mli.lazyPath());
    sources.gen.put(.parser_ml, gen.parser_ml.lazyPath());
    sources.gen.put(.parser_mli, gen.parser_mli.lazyPath());
    sources.gen.put(.parsing_lexer_ml, lexer.run(src.path("parsing/lexer.mll"), "lexer.ml"));
    sources.gen.put(.byterntm_ml, lexer.run(src.path("bytecomp/byterntm.mll"), "byterntm.ml"));
    sources.gen.put(.opcodes_ml, opcodes_ml);
    sources.gen.put(.opcodes_mli, opcodes_mli);
    sources.gen.put(.opnames_ml, opnames_ml);
    sources.gen.put(.emit_ml, emit_ml);
    sources.gen.put(.lex_parser_ml, yacc_prefix.dirname().path(b, "parser.ml"));
    sources.gen.put(.lex_parser_mli, yacc_prefix.dirname().path(b, "parser.mli"));
    sources.gen.put(.lex_lexer_ml, lexer.run(src.path("lex/lexer.mll"), "lexer.ml"));

    // 5. Compile all compiler and ocamllex modules
    const cc = m.compiler;
    const compiled = boot.compilePlan(cc.plan, sources, .{ .flags = cc.compflags });
    const lex = boot.compilePlan(m.lex.plan, sources, .{ .flags = cc.compflags });

    const compilerlibs = b.addWriteFiles();
    _ = compilerlibs.add("META", src.renderMeta("compilerlibs/META.in", &.{}));
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

    // 6. compilerlibs/*.cma
    const archive = struct {
        fn f(o: Ocamlc, c: Ocamlc.Compiled, wf: *std.Build.Step.WriteFile, name: []const u8, keys: []const []const u8, flags: []const []const u8) LazyPath {
            const cma = o.archive(name, c.cmos(o.b, keys), .{ .flags = flags });
            _ = wf.addCopyFile(cma, name);
            return cma;
        }
    }.f;
    const ocamlcommon = archive(boot, compiled, compilerlibs, "ocamlcommon.cma", cc.ocamlcommon, &.{"-linkall"});
    const ocamlbytecomp = archive(boot, compiled, compilerlibs, "ocamlbytecomp.cma", cc.ocamlbytecomp, &.{});
    const ocamlmiddleend = archive(boot, compiled, compilerlibs, "ocamlmiddleend.cma", cc.ocamlmiddleend, &.{});
    const ocamloptcomp = archive(boot, compiled, compilerlibs, "ocamloptcomp.cma", cc.ocamloptcomp, &.{});
    const ocamltoplevel = archive(boot, compiled, compilerlibs, "ocamltoplevel.cma", cc.ocamltoplevel, &.{});

    // 7. Programs
    const linker: Linker = .{ .ocamlc = boot, .cmis_dir = compiled.cmis_dir, .launch_flags = launch_flags };
    const cmo = struct {
        fn f(c: Ocamlc.Compiled, key: []const u8) LazyPath {
            return c.cmo(key).?;
        }
    }.f;

    const expunge = linker.link("expunge.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "toplevel/expunge") }, &.{});
    const ocaml_tmp = linker.link("ocaml.tmp", &.{ ocamlcommon, ocamlbytecomp, ocamltoplevel, cmo(compiled, "toplevel/topstart") }, &.{ "-linkall", "-g" });
    const ocaml = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(expunge);
        run.addFileArg(ocaml_tmp);
        const out = run.addOutputFileArg("ocaml");
        run.addArgs(m.stdlib.pervasives);
        break :blk out;
    };

    const lex_linker: Linker = .{ .ocamlc = boot, .cmis_dir = lex.cmis_dir, .launch_flags = launch_flags };
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
        .ocamlc_stripped = stripByteProg(b, options.build_ocamlrun, stripdebug, ocamlc_byte, "ocamlc.byte.stripped"),
        .ocamlopt = ocamlopt_byte,
        .ocamlopt_stripped = stripByteProg(b, options.build_ocamlrun, stripdebug, ocamlopt_byte, "ocamlopt.byte.stripped"),
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
        .compilerlibs_dir = compilerlibs.getDirectory(),
        .profiling_dir = profiling.getDirectory(),
        .sources = sources,
        .compiled = compiled,
        .lex = lex,
        .ocamlopt = .{
            .b = b,
            .ocamlrun = options.build_ocamlrun,
            .exe = programs.ocamlopt,
            .stdlib_dir = options.stdlib.dir,
            .prefix_map = prefix_map,
            .cwd = src.path(""),
        },
        .ocamlc = .{
            .b = b,
            .ocamlrun = options.build_ocamlrun,
            .exe = programs.ocamlc,
            .stdlib_dir = options.stdlib.dir,
            .primitives = null,
            .prefix_map = prefix_map,
            .cwd = src.path(""),
        },
    };
}

/// `opt` determines the machine code, while `byte.sources` determines the
/// compiler's code generator. Pass `dynlink_dir = null` when only building
/// host-native cross-compiler executables (`programs = true`).
pub fn buildNative(src: *const Source, byte: Artifacts, opt: Ocamlopt, rt: runtime.Artifacts, dynlink_dir: ?LazyPath, programs: bool) Artifacts {
    const b = src.b;
    const cc = src.manifest.compiler;
    const compiled = opt.compilePlan(cc.plan, byte.sources, byte.compiled, .{
        .includes = if (dynlink_dir) |d| &.{d} else &.{},
        .flags = cc.compflags,
        .skip_toplevel = dynlink_dir == null,
    });

    const libs: ?*std.Build.Step.WriteFile = if (dynlink_dir != null) b.addWriteFiles() else null;
    const profiling: ?*std.Build.Step.WriteFile = if (dynlink_dir != null) b.addWriteFiles() else null;
    if (libs) |l| {
        _ = l.addCopyDirectory(byte.compilerlibs_dir, "", .{});
        _ = profiling.?.addCopyDirectory(byte.profiling_dir, "", .{});
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
    const common = archive(opt, compiled, libs, "ocamlcommon", cc.ocamlcommon, &.{ "-linkall", "-cclib", "-lcomprmarsh", "-cclib", "-lzstd" });
    const bytecomp = archive(opt, compiled, libs, "ocamlbytecomp", cc.ocamlbytecomp, &.{});
    const middleend = archive(opt, compiled, libs, "ocamlmiddleend", cc.ocamlmiddleend, &.{});
    const optcomp = archive(opt, compiled, libs, "ocamloptcomp", cc.ocamloptcomp, &.{});
    const toplevel = if (libs != null) archive(opt, compiled, libs, "ocamltoplevel", cc.ocamltoplevel_native, &.{}) else null;

    var result = byte;
    if (libs) |l| {
        result.compilerlibs_dir = l.getDirectory();
        result.profiling_dir = profiling.?.getDirectory();
    }
    if (programs or toplevel != null) {
        const runtime_dir = b.addWriteFiles();
        _ = runtime_dir.addCopyFile(rt.libasmrun.?.getEmittedBin(), "libasmrun.a");
        _ = runtime_dir.addCopyFile(rt.libcomprmarsh.getEmittedBin(), "libcomprmarsh.a");
        _ = runtime_dir.addCopyFile(rt.zstd_lib.getEmittedBin(), "libzstd.a");
        const std_flags: []const []const u8 = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin };

        if (toplevel) |tl| {
            result.ocamlnat = opt.link(
                "ocamlnat",
                &.{ common, optcomp, bytecomp, dynlink_dir.?.path(b, "dynlink.cmxa"), tl, compiled.impls.get("toplevel/topstart").?.impl.cmx },
                .{
                    .includes = &.{ byte.compiled.cmis_dir, compiled.dir, runtime_dir.getDirectory(), dynlink_dir.? },
                    .flags = Ocamlc.concat(b, std_flags, &.{"-linkall"}),
                },
            );
        }
        if (programs) {
            const lex = opt.compilePlan(src.manifest.lex.plan, byte.sources, byte.lex, .{ .flags = cc.compflags });
            const opts: Ocamlopt.Options = .{
                .includes = &.{ byte.compiled.cmis_dir, compiled.dir, runtime_dir.getDirectory(), lex.dir },
                .flags = std_flags,
            };
            result.native_programs = .{
                .ocamlc = opt.link("ocamlc.opt", &.{ common, bytecomp, compiled.impls.get("driver/main").?.impl.cmx }, opts),
                .ocamlopt = opt.link("ocamlopt.opt", &.{ common, optcomp, compiled.impls.get("driver/optmain").?.impl.cmx }, opts),
                .ocamllex = opt.link("ocamllex.opt", lex.cmxs(b, src.manifest.lex.ocamllex), opts),
                .ocamldep = opt.link("ocamldep.opt", &.{ common, bytecomp, compiled.impls.get("tools/ocamldep").?.impl.cmx }, opts),
                .ocamlobjinfo = opt.link("ocamlobjinfo.opt", &.{ common, bytecomp, middleend, compiled.impls.get("tools/objinfo").?.impl.cmx }, opts),
            };
        }
    }
    return result;
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

    const stublibs = b.addWriteFiles();
    if (libs.unix_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.unix_stubs.dllName(host));
    const linker: Linker = .{ .ocamlc = comp.ocamlc, .cmis_dir = comp.compiled.cmis_dir, .launch_flags = launchFlags(b, host) };
    const exe = comp.ocamlc.link("ocamldebug", &.{
        comp.compilerlibs_dir.path(b, "ocamlcommon.cma"),
        libs.unix_dir.path(b, "unix.cma"),
        libs.dynlink_dir.path(b, "dynlink.cma"),
        comp.compiled.cmo("toplevel/genprintval").?,
        comp.compiled.cmo("toplevel/topprinters").?,
        packed_cmo,
        entry_impl.cmo,
    }, .{
        .includes = &.{ comp.compiled.cmis_dir, libs.unix_dir, libs.dynlink_dir, dbg.cmis_dir, packed_cmo.dirname(), stublibs.getDirectory() },
        .flags = Ocamlc.concat(b, linker.launch_flags, &.{"-linkall"}),
    });
    return .{
        .exe = exe,
        .cmi = packed_cmo.dirname().path(b, "ocamldebug.cmi"),
        .parser_aux_cmi = dbg.intfs.get("debugger/parser_aux").?.cmi,
    };
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

    var byte_objs: std.ArrayList(LazyPath) = .empty;
    byte_objs.appendSlice(b.allocator, &.{
        comp.compilerlibs_dir.path(b, "ocamlcommon.cma"),
        libs.unix_dir.path(b, "unix.cma"),
        libs.str_dir.path(b, "str.cma"),
        libs.dynlink_dir.path(b, "dynlink.cma"),
        odoc_info_cma,
    }) catch @panic("OOM");
    byte_objs.appendSlice(b.allocator, odoc_byte.cmos(b, m.ocamldoc.ocamldoc)) catch @panic("OOM");

    const stublibs = b.addWriteFiles();
    if (libs.unix_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.unix_stubs.dllName(rt.platform));
    if (libs.str_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.str_stubs.dllName(rt.platform));
    const byte_exe = comp.ocamlc.link("ocamldoc.byte", byte_objs.items, .{
        .includes = &.{ odoc_byte.cmis_dir, stublibs.getDirectory() },
        .flags = launchFlags(b, host),
    });

    var opt_exe: ?LazyPath = null;
    if (rt.platform.hasNativeCompiler()) {
        const nat_includes: []const LazyPath = &.{ comp.compiled.cmis_dir, comp.compilerlibs_dir, libs.unix_dir, libs.str_dir, libs.dynlink_dir };
        const odoc_nat = comp.ocamlopt.compilePlan(m.ocamldoc.plan, sources, odoc_byte, .{
            .includes = nat_includes,
            .flags = m.compiler.compflags,
        });
        const odoc_info_nat = comp.ocamlopt.archive("odoc_info", odoc_nat.cmxs(b, m.ocamldoc.odoc_info), .{});
        _ = lib_wf.addCopyFile(odoc_info_nat.cmxa, "odoc_info.cmxa");
        _ = lib_wf.addCopyFile(odoc_info_nat.lib, "odoc_info.a");
        for (odoc_nat.impls.values()) |u| {
            if (std.mem.eql(u8, u.unit.name, "odoc_test")) continue;
            _ = lib_wf.addCopyFile(u.impl.cmx, b.fmt("{s}.cmx", .{u.unit.name}));
        }

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
            odoc_info_nat.cmxa,
        }) catch @panic("OOM");
        nat_objs.appendSlice(b.allocator, odoc_nat.cmxs(b, m.ocamldoc.ocamldoc)) catch @panic("OOM");

        opt_exe = comp.ocamlopt.link("ocamldoc.opt", nat_objs.items, .{
            .includes = &.{ comp.compiled.cmis_dir, comp.compilerlibs_dir, runtime_dir.getDirectory(), libs.unix_dir, libs.str_dir, libs.dynlink_dir, odoc_nat.dir },
            .flags = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ stdlib_dir_from_bin },
        });
    }

    return .{ .byte = byte_exe, .opt = opt_exe, .lib_dir = lib_wf.getDirectory() };
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
    cmis_dir: LazyPath,
    launch_flags: []const []const u8,

    fn link(self: Linker, name: []const u8, objs: []const LazyPath, flags: []const []const u8) LazyPath {
        return self.ocamlc.link(name, objs, .{
            .includes = &.{self.cmis_dir},
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
fn buildTool(boot: Ocamlc, src_ml: LazyPath, name: []const u8, launch_flags: []const []const u8) LazyPath {
    const compiled = boot.impl(src_ml, name, null, .{});
    return boot.link(boot.b.fmt("{s}.byte", .{name}), &.{compiled.cmo}, .{ .flags = launch_flags });
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
    const native_ldflags = if (target.is_macos and target.arch == .amd64) "-Wl,-no_compact_unwind" else "";
    // Zig on PATH keeps installed compilers relocatable, without system cross-gcc.
    const triple = target.resolved.result.zigTriple(b.allocator) catch @panic("OOM");
    const cc = b.fmt("zig cc -target {s} -fno-sanitize=undefined{s}", .{ triple, if (target.resolved.result.abi.isMusl()) " -dynamic" else "" });
    const asm_cmd = b.fmt("{s}{s} -c", .{ cc, if (target.arch == .riscv) " -mcpu=baseline_rv64-c-zca-zcd" else "" });
    const packld = b.fmt("{s} -nostdlib -r -o ", .{cc});
    const mkdll = b.fmt("{s} -shared{s}", .{ cc, if (target.is_macos) " -undefined dynamic_lookup -Wl,-w" else "" });
    const mkexe = b.fmt("{s} {s}{s}", .{ cc, cflags, if (target.is_elf) " -Wl,-E" else "" });
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
        .{ .name = "supports_shared_libraries", .value = "true" },
        .{ .name = "natdynlink", .value = "true" },
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
