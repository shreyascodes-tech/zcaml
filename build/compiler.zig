//! The bytecode compilers and tools (`ocamlc`, `ocamlopt`, `ocamllex`, ...) and
//! `compiler-libs`, compiled with `boot/ocamlc`.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const Ocamlc = @import("ocamlc.zig");
const Ocamlopt = @import("ocamlopt.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const Tools = @import("tools/root.zig");
const LazyPath = std.Build.LazyPath;

pub const Artifacts = struct {
    /// Bytecode executables, to be run by the host `ocamlrun`.
    programs: Programs,
    compilerlibs_dir: LazyPath,
    profiling_dir: LazyPath,
    /// Source resolver for compiler modules (otherlibs reuse it for dynlink).
    sources: Source.Resolver,
    /// The freshly built `ocamlc`, for compiling libraries against the new stdlib.
    ocamlc: Ocamlc,
    ocamlopt: Ocamlopt,
};

pub const Programs = struct {
    ocamlc: LazyPath,
    ocamlopt: LazyPath,
    ocamllex: LazyPath,
    ocamldep: LazyPath,
    ocamlobjinfo: LazyPath,
    ocamlcmt: LazyPath,
    ocamlprof: LazyPath,
    ocamlcp: LazyPath,
    ocamloptp: LazyPath,
    ocamlmklib: LazyPath,
    ocamlmktop: LazyPath,
    expunge: LazyPath,
    /// The toplevel (`ocaml`).
    ocaml: LazyPath,
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
    const features = m.features;
    const host = options.host;
    const target = options.target_rt.platform;

    // 1. utils/config_main.ml, utils/config_boot.ml, compilerlibs/META
    const config_common = if (features.config_common_template) renderConfigCommon(src.*) else src.read("utils/config.common.ml");
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
    if (features.yacc_strict) yacc_run.addArg("--strict");
    yacc_run.addArg("-b");
    const yacc_prefix = yacc_run.addOutputFileArg("parser");
    yacc_run.addFileArg(src.path("lex/parser.mly"));

    const lexer: Lexer = .{ .b = b, .ocamlrun = options.build_ocamlrun, .exe = src.path("boot/ocamllex") };

    // 4. tools/make_opcodes and tools/cvt_emit -> opcodes.ml{,i}, opnames.ml, emit.ml
    const boot: Ocamlc = .{
        .b = b,
        .ocamlrun = options.build_ocamlrun,
        .exe = src.path("boot/ocamlc"),
        .stdlib_dir = options.stdlib.dir,
        .primitives = options.target_rt.primitives,
    };
    const launch_flags = launchFlags(b, src.*, host);
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
    if (features.byterntm) sources.gen.put(.byterntm_ml, lexer.run(src.path("bytecomp/byterntm.mll"), "byterntm.ml"));
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
    const programs: Programs = .{
        .ocamlc = linker.link("ocamlc.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "driver/main") }, &.{ "-compat-32", "-g" }),
        .ocamlopt = linker.link("ocamlopt.byte", &.{ ocamlcommon, ocamloptcomp, cmo(compiled, "driver/optmain") }, &.{"-g"}),
        .ocamllex = lex_linker.link("ocamllex.byte", lex.cmos(b, m.lex.ocamllex), &.{"-compat-32"}),
        .ocamldep = linker.link("ocamldep.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/ocamldep") }, &.{"-compat-32"}),
        .ocamlobjinfo = linker.link("ocamlobjinfo.byte", &.{ ocamlcommon, ocamlbytecomp, ocamlmiddleend, cmo(compiled, "tools/objinfo") }, &.{}),
        .ocamlcmt = linker.link("ocamlcmt.byte", &.{ ocamlcommon, ocamlbytecomp, cmo(compiled, "tools/ocamlcmt") }, &.{}),
        .ocamlprof = linker.link("ocamlprof.byte", compiled.cmos(b, cc.ocamlprof), &.{}),
        .ocamlcp = linker.link("ocamlcp.byte", compiled.cmos(b, cc.ocamlcp), &.{}),
        .ocamloptp = linker.link("ocamloptp.byte", compiled.cmos(b, cc.ocamloptp), &.{}),
        .ocamlmklib = linker.link("ocamlmklib.byte", compiled.cmos(b, cc.ocamlmklib), &.{}),
        .ocamlmktop = linker.link("ocamlmktop.byte", compiled.cmos(b, cc.ocamlmktop), &.{}),
        .expunge = expunge,
        .ocaml = ocaml,
    };

    return .{
        .programs = programs,
        .compilerlibs_dir = compilerlibs.getDirectory(),
        .profiling_dir = profiling.getDirectory(),
        .sources = sources,
        .ocamlopt = .{
            .b = b,
            .ocamlrun = options.build_ocamlrun,
            .exe = programs.ocamlopt,
            .stdlib_dir = options.stdlib.dir,
        },
        .ocamlc = .{
            .b = b,
            .ocamlrun = options.build_ocamlrun,
            .exe = programs.ocamlc,
            .stdlib_dir = options.stdlib.dir,
            .primitives = null,
        },
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
fn launchFlags(b: *std.Build, src: Source, host: Platform) []const []const u8 {
    if (!src.manifest.features.relocatable) return &.{};
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
    const mn = src.manifest.version.magic.?.numbers;
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
    const libdir = stdlib_dir_from_bin;

    const cflags = c.cflagsString(b);
    const cppflags = c.cppflagsString(b);
    const cclibs = c.libsString(b);
    const rpath = if (target.is_elf) "-Wl,-rpath," else "";
    const native_ldflags = if (target.is_macos and target.arch == .amd64) "-Wl,-no_compact_unwind" else "";
    // Zig on PATH keeps installed compilers relocatable, without system cross-gcc.
    const triple = target.resolved.result.zigTriple(b.allocator) catch @panic("OOM");
    const cc = b.fmt("zig cc -target {s} -fno-sanitize=undefined", .{triple});
    const asm_cmd = b.fmt("{s} -c", .{cc});
    const packld = b.fmt("{s} -nostdlib -r -o ", .{cc});
    const mkdll = b.fmt("{s} -shared{s}", .{ cc, if (target.is_macos) " -undefined dynamic_lookup -Wl,-w" else "" });
    const mkexe = b.fmt("{s} {s}{s}", .{ cc, cflags, if (target.is_elf) " -Wl,-E" else "" });
    const so_ext = target.dllExt();
    const bool_str = struct {
        fn f(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.f;

    if (!src.manifest.features.config_generated_template) {
        return src.renderPercent("utils/config.mlp", &.{
            .{ .name = "BINDIR", .value = bindir },
            .{ .name = "LIBDIR", .value = libdir },
            .{ .name = "CCOMPTYPE", .value = "cc" },
            .{ .name = "CC", .value = cc },
            .{ .name = "OUTPUTOBJ", .value = "-o " },
            .{ .name = "CC_HAS_DEBUG_PREFIX_MAP", .value = "true" },
            .{ .name = "AS_HAS_DEBUG_PREFIX_MAP", .value = "true" },
            .{ .name = "OCAMLC_CFLAGS", .value = cflags },
            .{ .name = "OCAMLC_CPPFLAGS", .value = cppflags },
            .{ .name = "OCAMLOPT_CPPFLAGS", .value = cppflags },
            .{ .name = "BYTECCLIBS", .value = cclibs },
            .{ .name = "NATIVECCLIBS", .value = cclibs },
            .{ .name = "PACKLD", .value = packld },
            .{ .name = "RPATH", .value = rpath },
            .{ .name = "MKSHAREDLIBRPATH", .value = rpath },
            .{ .name = "ARCMD", .value = "zig ar" },
            .{ .name = "SUPPORTS_SHARED_LIBRARIES", .value = "true" },
            .{ .name = "FLEXDLL_CHAIN", .value = if (target.is_windows) "mingw64" else "" },
            .{ .name = "FLEXLINK_FLAGS", .value = if (target.is_windows) "-stack 33554432" else "" },
            .{ .name = "FLEXLINK_DLL_LDFLAGS", .value = "" },
            .{ .name = "FLEXLINK_LDFLAGS", .value = if (target.is_windows) " -link -municode" else "" },
            .{ .name = "MKDLL_EXP", .value = mkdll },
            .{ .name = "MKEXE_EXP", .value = mkexe },
            .{ .name = "MKMAINDLL", .value = mkdll },
            .{ .name = "FLAMBDA", .value = "false" },
            .{ .name = "WITH_FLAMBDA_INVARIANTS", .value = "false" },
            .{ .name = "WITH_CMM_INVARIANTS", .value = "false" },
            .{ .name = "WINDOWS_UNICODE", .value = if (target.is_windows) "1" else "0" },
            .{ .name = "FLAT_FLOAT_ARRAY", .value = "true" },
            .{ .name = "FUNCTION_SECTIONS", .value = bool_str(target.is_elf) },
            .{ .name = "AFL_INSTRUMENT", .value = "false" },
            .{ .name = "ARCH", .value = target.archName() },
            .{ .name = "MODEL", .value = target.model },
            .{ .name = "SYSTEM", .value = target.system },
            .{ .name = "ASM", .value = asm_cmd },
            .{ .name = "ASM_CFI_SUPPORTED", .value = bool_str(!target.is_windows) },
            .{ .name = "WITH_FRAME_POINTERS", .value = "false" },
            .{ .name = "WITH_PROFINFO", .value = "false" },
            .{ .name = "PROFINFO_WIDTH", .value = "0" },
            .{ .name = "EXE", .value = target.exeExt() },
            .{ .name = "EXT_OBJ", .value = ".o" },
            .{ .name = "EXT_ASM", .value = ".s" },
            .{ .name = "EXT_LIB", .value = ".a" },
            .{ .name = "EXT_DLL", .value = b.fmt(".{s}", .{so_ext}) },
            .{ .name = "HOST", .value = host.triplet },
            .{ .name = "TARGET", .value = target.triplet },
            .{ .name = "SYSTHREAD_SUPPORT", .value = "true" },
            .{ .name = "FLEXDLL_DIR", .value = "" },
        });
    }

    const runtime_id = target.runtimeId(b, src.manifest.version);
    return src.renderAt("utils/config.generated.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from utils/config.generated.ml.in" },
        .{ .name = "QS", .value = "" },
        .{ .name = "ocaml_bindir", .value = bindir },
        .{ .name = "TARGET_BINDIR", .value = bindir, .version_specific = true },
        .{ .name = "ocaml_libdir", .value = libdir, .version_specific = true },
        .{ .name = "ccomptype", .value = "cc", .version_specific = true },
        .{ .name = "ccomp_type", .value = "cc", .version_specific = true },
        .{ .name = "CC", .value = cc },
        .{ .name = "ocaml_cc_vendor", .value = "clang-19", .version_specific = true },
        .{ .name = "outputobj", .value = "-o " },
        .{ .name = "cc_has_debug_prefix_map", .value = "true" },
        .{ .name = "as_has_debug_prefix_map", .value = "true", .version_specific = true },
        .{ .name = "ocaml_cv_prog_as_debug_prefix_map", .value = "true", .version_specific = true },
        .{ .name = "as_is_cc", .value = "true", .version_specific = true },
        .{ .name = "ocamlc_cflags", .value = cflags, .version_specific = true },
        .{ .name = "ocamlc_cppflags", .value = cppflags, .version_specific = true },
        .{ .name = "bytecode_cflags", .value = cflags, .version_specific = true },
        .{ .name = "bytecode_cppflags", .value = cppflags, .version_specific = true },
        .{ .name = "native_cflags", .value = cflags, .version_specific = true },
        .{ .name = "native_cppflags", .value = cppflags, .version_specific = true },
        .{ .name = "zstd_libs", .value = "" },
        .{ .name = "cclibs", .value = cclibs },
        .{ .name = "native_ldflags", .value = native_ldflags, .version_specific = true },
        .{ .name = "with_nonexecstack_note", .value = bool_str(target.is_linux and target.is_elf), .version_specific = true },
        .{ .name = "PACKLD", .value = packld },
        .{ .name = "rpath", .value = rpath },
        .{ .name = "mksharedlibrpath", .value = rpath },
        .{ .name = "AR", .value = "zig ar" },
        .{ .name = "supports_shared_libraries", .value = "true" },
        .{ .name = "natdynlink", .value = "true" },
        .{ .name = "mkdll_exp", .value = mkdll },
        .{ .name = "mkexe_exp", .value = mkexe },
        .{ .name = "mkmaindll_exp", .value = mkdll },
        .{ .name = "flexdll_chain", .value = if (target.is_windows) "mingw64" else "", .version_specific = true },
        .{ .name = "flexlink_flags", .value = if (target.is_windows) "-stack 33554432" else "", .version_specific = true },
        .{ .name = "mkdll_ldflags_exp", .value = "", .version_specific = true },
        .{ .name = "mkexe_extra_flags", .value = if (target.is_windows) "-link -municode" else "", .version_specific = true },
        .{ .name = "mkexe_ldflags_exp", .value = "", .version_specific = true },
        .{ .name = "flambda", .value = "false" },
        .{ .name = "flambda_invariants", .value = "false" },
        .{ .name = "cmm_invariants", .value = "false" },
        .{ .name = "codegen_invariants", .value = "false", .version_specific = true },
        .{ .name = "windows_unicode", .value = if (target.is_windows) "1" else "0" },
        .{ .name = "flat_float_array", .value = "true" },
        .{ .name = "align_double", .value = bool_str(!target.arch64), .version_specific = true },
        .{ .name = "align_int64", .value = bool_str(!target.arch64), .version_specific = true },
        .{ .name = "function_sections", .value = bool_str(target.is_elf) },
        .{ .name = "afl", .value = "false" },
        .{ .name = "bytecode_runtime_id", .value = runtime_id, .version_specific = true },
        .{ .name = "native_runtime_id", .value = runtime_id, .version_specific = true },
        .{ .name = "native_compiler", .value = bool_str(target.hasNativeCompiler()) },
        .{ .name = "arch", .value = target.archName() },
        .{ .name = "model", .value = target.model },
        .{ .name = "system", .value = target.system },
        .{ .name = "target_os_type", .value = target.osType(), .version_specific = true },
        .{ .name = "AS", .value = asm_cmd },
        .{ .name = "asm_cfi_supported", .value = bool_str(!target.is_windows) },
        .{ .name = "asm_size_type_directives", .value = bool_str(target.is_elf), .version_specific = true },
        .{ .name = "asm_dwarf_version", .value = "None", .version_specific = true },
        .{ .name = "frame_pointers", .value = "false" },
        .{ .name = "reserved_header_bits", .value = "0" },
        .{ .name = "exeext", .value = target.exeExt(), .version_specific = true },
        .{ .name = "EXEEXT", .value = target.exeExt(), .version_specific = true },
        .{ .name = "OBJEXT", .value = "o" },
        .{ .name = "S", .value = "s" },
        .{ .name = "libext", .value = "a" },
        .{ .name = "SO", .value = so_ext },
        .{ .name = "host", .value = host.triplet },
        .{ .name = "target", .value = target.triplet },
        .{ .name = "systhread_support", .value = "true" },
        .{ .name = "flexdll_dir", .value = "" },
        .{ .name = "ar_supports_response_files", .value = "true" },
        .{ .name = "tsan", .value = "false", .version_specific = true },
        .{ .name = "shebangscripts", .value = bool_str(!host.is_windows), .version_specific = true },
        .{ .name = "suffixing", .value = "false", .version_specific = true },
        .{ .name = "launch_method_target", .value = if (target.is_windows) "exe" else "sh", .version_specific = true },
        .{ .name = "runtime_search_target", .value = "fallback", .version_specific = true },
    });
}
