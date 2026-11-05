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

pub const native_link_flags: []const []const u8 = &.{ "-g", "-set-runtime-default", "standard_library_default=" ++ configure.stdlib_dir_from_bin };

/// Target- and host-independent compiler bootstrap artifacts, built once per OCaml release.
pub const Shared = struct {
    config_common: []const u8,
    compilerlibs_meta: LazyPath,
    base_sources: Source.Resolver,
    cvt_emit: LazyPath,
    boot: Ocamlc,
    lex: Ocamlc.Compiled,
    build_ocamlrun: *std.Build.Step.Compile,
    /// The compiler's `compflags` without `-g -bin-annot`, for its bytecode build.
    byte_compflags: []const []const u8,
    frontend_byte: Ocamlc.Compiled,
    ocamlbytecomp_cma: LazyPath,
    ocamlmiddleend_cma: LazyPath,
    ocamltoplevel_cma: LazyPath,
    profiling_dir: LazyPath,
};

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

    const config_common = configure.compilerConfigCommon(src);
    const config_wf = b.addWriteFiles();
    const compilerlibs_meta = config_wf.add("META", src.renderMeta("compilerlibs/META.in", &.{}));

    const gen, _ = Tools.run(b, .gen_compiler_sources, .{
        .ocaml_src_dir = .of(src.path("")),
        .primitives = .of(rt_common.primitives),
        .ccomp_zig_cache_ml = .of(b.path("build/compiler/ccomp_zig_cache.ml")),
        .domainstate_ml = .of("domainstate.ml"),
        .domainstate_mli = .of("domainstate.mli"),
        .runtimedef_ml = .of("runtimedef.ml"),
        .menhir_lib_mli = .of("camlinternalMenhirLib.mli"),
        .parser_ml = .of("parser.ml"),
        .parser_mli = .of("parser.mli"),
        .ccomp_ml = .of("ccomp.ml"),
    });

    const lexer: Lexer = .{ .src = src, .ocamlrun = build_ocamlrun };

    const boot: Ocamlc = .{
        .b = b,
        .ocamlrun = build_ocamlrun,
        .exe = src.path("boot/ocamlc"),
        .stdlib_dir = stdlib_base_dir,
        .primitives = rt_common.primitives,
        .prefix_map = src.prefixMap(),
        .cwd = src.path(""),
    };
    const cvt_emit = boot.link("cvt_emit.byte", &.{boot.impl(lexer.run("tools/cvt_emit.mll"), "cvt_emit", null, .{}).cmo}, .{
        .includes = &.{build_launch_info_dir},
    });

    const lex_parser = runYacc(src, build_ocamlyacc, "lex/parser.mly");
    const dbg_parser = runYacc(src, build_ocamlyacc, "debugger/debugger_parser.mly");
    const text_parser = runYacc(src, build_ocamlyacc, "ocamldoc/odoc_text_parser.mly");
    const odoc_parser = runYacc(src, build_ocamlyacc, "ocamldoc/odoc_parser.mly");

    var base_sources: Source.Resolver = .{ .source = src, .arch = null };
    base_sources.gen.put(.domainstate_ml, src.nameSource(gen.domainstate_ml.lazyPath(), "utils/domainstate.ml"));
    base_sources.gen.put(.domainstate_mli, src.nameSource(gen.domainstate_mli.lazyPath(), "utils/domainstate.mli"));
    base_sources.gen.put(.runtimedef_ml, src.nameSource(gen.runtimedef_ml.lazyPath(), "lambda/runtimedef.ml"));
    base_sources.gen.put(.ccomp_ml, src.nameSource(gen.ccomp_ml.lazyPath(), "utils/ccomp.ml"));
    base_sources.gen.put(.camlinternalMenhirLib_mli, src.nameSource(gen.menhir_lib_mli.lazyPath(), "parsing/camlinternalMenhirLib.mli"));
    base_sources.gen.put(.parser_ml, src.nameSource(gen.parser_ml.lazyPath(), "parsing/parser.ml"));
    base_sources.gen.put(.parser_mli, src.nameSource(gen.parser_mli.lazyPath(), "parsing/parser.mli"));
    base_sources.gen.put(.parsing_lexer_ml, lexer.run("parsing/lexer.mll"));
    base_sources.gen.put(.byterntm_ml, lexer.run("bytecomp/byterntm.mll"));
    base_sources.gen.put(.opcodes_ml, src.nameSource(rt_common.opcodes_ml, "bytecomp/opcodes.ml"));
    base_sources.gen.put(.opcodes_mli, src.nameSource(rt_common.opcodes_mli, "bytecomp/opcodes.mli"));
    base_sources.gen.put(.opnames_ml, src.nameSource(rt_common.opnames_ml, "tools/opnames.ml"));
    base_sources.gen.put(.lex_parser_ml, lex_parser.ml);
    base_sources.gen.put(.lex_parser_mli, lex_parser.mli);
    base_sources.gen.put(.lex_lexer_ml, lexer.run("lex/lexer.mll"));
    base_sources.gen.put(.debugger_parser_ml, dbg_parser.ml);
    base_sources.gen.put(.debugger_parser_mli, dbg_parser.mli);
    base_sources.gen.put(.debugger_lexer_ml, lexer.run("debugger/debugger_lexer.mll"));
    base_sources.gen.put(.odoc_text_parser_ml, text_parser.ml);
    base_sources.gen.put(.odoc_text_parser_mli, text_parser.mli);
    base_sources.gen.put(.odoc_parser_ml, odoc_parser.ml);
    base_sources.gen.put(.odoc_parser_mli, odoc_parser.mli);
    base_sources.gen.put(.odoc_text_lexer_ml, lexer.run("ocamldoc/odoc_text_lexer.mll"));
    base_sources.gen.put(.odoc_lexer_ml, lexer.run("ocamldoc/odoc_lexer.mll"));
    base_sources.gen.put(.odoc_see_lexer_ml, lexer.run("ocamldoc/odoc_see_lexer.mll"));
    base_sources.gen.put(.odoc_ocamlhtml_ml, lexer.run("ocamldoc/odoc_ocamlhtml.mll"));

    var byte_compflags: std.ArrayList([]const u8) = .empty;
    for (m.compiler.compflags) |f| {
        if (std.mem.eql(u8, f, "-bin-annot") or std.mem.eql(u8, f, "-g")) continue;
        byte_compflags.append(b.allocator, f) catch @panic("OOM");
    }

    const lex = boot.compilePlan(m.lex.plan, base_sources, .{ .flags = byte_compflags.items });

    const frontend_byte = boot.compilePlan(m.compiler.plan, base_sources, .{
        .flags = byte_compflags.items,
        .only_frontend = true,
    });

    const ocamlbytecomp_cma = boot.archive("ocamlbytecomp.cma", frontend_byte.cmos(b, m.compiler.ocamlbytecomp), .{});
    const ocamlmiddleend_cma = boot.archive("ocamlmiddleend.cma", frontend_byte.cmos(b, m.compiler.ocamlmiddleend), .{});
    const ocamltoplevel_cma = boot.archive("ocamltoplevel.cma", frontend_byte.cmos(b, m.compiler.ocamltoplevel), .{});

    const profiling = b.addWriteFiles();
    for (frontend_byte.intfs.values()) |u| {
        if (u.unit.dest == .profiling) {
            _ = profiling.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        }
    }
    for (frontend_byte.impls.values()) |u| {
        if (u.unit.dest == .profiling) {
            _ = profiling.addCopyFile(u.impl.cmo, b.fmt("{s}.cmo", .{u.unit.name}));
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
        .byte_compflags = byte_compflags.items,
        .frontend_byte = frontend_byte,
        .ocamlbytecomp_cma = ocamlbytecomp_cma,
        .ocamlmiddleend_cma = ocamlmiddleend_cma,
        .ocamltoplevel_cma = ocamltoplevel_cma,
        .profiling_dir = profiling.getDirectory(),
    };
}

/// Architecture-dependent bytecode compiler artifacts (`boot/ocamlc` output), built once per `Arch`.
pub const ArchByte = struct {
    arch: ?Platform.Arch,
    sources: Source.Resolver,
    compiled: Ocamlc.Compiled,
    base_compilerlibs_dir: LazyPath,
    ocamloptcomp_cma: LazyPath,
};

pub fn buildArchByte(src: *const Source, shared: Shared, arch: ?Platform.Arch) ArchByte {
    const b = src.b;
    const cc = src.manifest.compiler;
    const arch_name = if (arch) |a| @tagName(a) else "none";

    var sources = shared.base_sources;
    sources.arch = arch;
    if (arch != null) {
        const emit_mlp = b.fmt("asmcomp/{s}/emit.mlp", .{arch_name});
        const cvt_emit = b.addRunArtifact(shared.build_ocamlrun);
        cvt_emit.addFileArg(shared.cvt_emit);
        cvt_emit.setStdIn(.{ .lazy_path = src.path(emit_mlp) });
        sources.gen.put(.emit_ml, src.nameSource(cvt_emit.captureStdOut(.{}), emit_mlp));
    }

    const compiled = shared.boot.compilePlan(cc.plan, sources, .{
        .flags = shared.byte_compflags,
        .reuse_frontend = shared.frontend_byte,
    });

    const compilerlibs = b.addWriteFiles();
    _ = compilerlibs.addCopyFile(shared.compilerlibs_meta, "META");

    for (compiled.intfs.values()) |u| {
        if (u.unit.dest != .lib) continue;
        _ = compilerlibs.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        if (u.cmti != null) {
            _ = compilerlibs.addCopyFile(u.src, b.fmt("{s}.mli", .{u.unit.name}));
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

pub const ByteCommon = struct {
    config_main_ml: LazyPath,
    ocamlcommon_cma: LazyPath,
    base_compilerlibs_dir: LazyPath,
    compiled: Ocamlc.Compiled,
    ocamlc_byte: LazyPath,
    ocamlopt_byte: LazyPath,
};

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
    const config_main_ml = config_wf.add("config_main.ml", Source.namedText(b, "utils/config_main.ml", configure.compilerConfigMl(src, shared.config_common, host, target)));

    const cfg_intf = arch_byte.compiled.intfs.get("utils/config").?;
    const cfg_impl = boot.impl(config_main_ml, "config", cfg_intf.cmi, .{
        .includes = &.{arch_byte.compiled.cmis_dir},
        .flags = shared.byte_compflags,
    });

    var compiled = arch_byte.compiled;
    compiled.impls = arch_byte.compiled.impls.clone(b.allocator) catch @panic("OOM");
    compiled.impls.put(b.allocator, "utils/config", .{ .unit = cfg_intf.unit, .impl = cfg_impl }) catch @panic("OOM");

    const ocamlcommon = boot.archive("ocamlcommon.cma", compiled.cmos(b, cc.ocamlcommon), .{ .flags = &.{"-linkall"} });

    const launch_flags = launchFlags(b, host);
    const linker: Linker = .{
        .ocamlc = boot,
        .includes = &.{ compiled.cmis_dir, host_launch_info_dir },
        .launch_flags = launch_flags,
    };
    const ocamlc_byte = linker.link("ocamlc.byte", &.{ ocamlcommon, shared.ocamlbytecomp_cma, compiled.cmo("driver/main").? }, &.{"-compat-32"});
    const ocamlopt_byte = linker.link("ocamlopt.byte", &.{ ocamlcommon, arch_byte.ocamloptcomp_cma, compiled.cmo("driver/optmain").? }, &.{});

    return .{
        .config_main_ml = config_main_ml,
        .ocamlcommon_cma = ocamlcommon,
        .base_compilerlibs_dir = arch_byte.base_compilerlibs_dir,
        .compiled = compiled,
        .ocamlc_byte = ocamlc_byte,
        .ocamlopt_byte = ocamlopt_byte,
    };
}

pub const BytecodeTools = struct {
    cmpbyt: LazyPath,
    dumpobj: LazyPath,
    primreq: LazyPath,
    stripdebug: LazyPath,
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
    bytecode_tools: ?BytecodeTools = null,
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

pub const Artifacts = struct {
    /// Bytecode executables, to be run by the host `ocamlrun`.
    programs: Programs,
    base_compilerlibs_dir: LazyPath,
    ocamlcommon_cma: LazyPath,
    nat_compilerlibs_dir: ?LazyPath = null,
    nat_common: ?NativeCommon = null,
    byte_profiling_dir: LazyPath,
    nat_profiling_dir: ?LazyPath = null,
    native_programs: ?NativePrograms = null,
};

pub fn buildBytePrograms(
    src: *const Source,
    shared: Shared,
    byte_common: ByteCommon,
    host: Platform,
    host_launch_info_dir: LazyPath,
    with_bytecode_tools: bool,
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

    const expunge = linker.link("expunge.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("toplevel/expunge").? }, &.{});
    const ocaml_tmp = linker.link("ocaml.tmp", &.{ ocamlcommon, ocamlbytecomp, ocamltoplevel, compiled.cmo("toplevel/topstart").? }, &.{"-linkall"});
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

    const programs: Programs = .{
        .ocamlc = byte_common.ocamlc_byte,
        .ocamlopt = byte_common.ocamlopt_byte,
        .ocamllex = lex_linker.link("ocamllex.byte", lex.cmos(b, m.lex.ocamllex), &.{"-compat-32"}),
        .ocamldep = linker.link("ocamldep.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("tools/ocamldep").? }, &.{"-compat-32"}),
        .ocamlobjinfo = linker.link("ocamlobjinfo.byte", &.{ ocamlcommon, ocamlbytecomp, ocamlmiddleend, compiled.cmo("tools/objinfo").? }, &.{}),
        .ocamlcmt = linker.link("ocamlcmt.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("tools/ocamlcmt").? }, &.{}),
        .ocamlprof = linker.link("ocamlprof.byte", compiled.cmos(b, cc.ocamlprof), &.{}),
        .ocamlcp = linker.link("ocamlcp.byte", compiled.cmos(b, cc.ocamlcp), &.{}),
        .ocamloptp = linker.link("ocamloptp.byte", compiled.cmos(b, cc.ocamloptp), &.{}),
        .ocamlmklib = linker.link("ocamlmklib.byte", compiled.cmos(b, cc.ocamlmklib), &.{}),
        .ocamlmktop = linker.link("ocamlmktop.byte", compiled.cmos(b, cc.ocamlmktop), &.{}),
        .bytecode_tools = if (with_bytecode_tools) .{
            .cmpbyt = linker.link("cmpbyt.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("tools/cmpbyt").? }, &.{}),
            .dumpobj = linker.link("dumpobj.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("tools/opnames").?, compiled.cmo("tools/dumpobj").? }, &.{}),
            .primreq = linker.link("primreq.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("tools/primreq").? }, &.{}),
            .stripdebug = linker.link("stripdebug.byte", &.{ ocamlcommon, ocamlbytecomp, compiled.cmo("tools/stripdebug").? }, &.{}),
        } else null,
        .expunge = expunge,
        .ocaml = ocaml,
    };

    return .{
        .programs = programs,
        .base_compilerlibs_dir = byte_common.base_compilerlibs_dir,
        .ocamlcommon_cma = ocamlcommon,
        .byte_profiling_dir = shared.profiling_dir,
    };
}

/// Architecture-dependent native compiler artifacts (`ocamlopt` output), built once per `(arch, system)` or `(host, target_arch)`.
pub const ArchNative = struct {
    compiled: Ocamlopt.Compiled,
    bytecomp_cmxa: LazyPath,
    middleend_cmxa: LazyPath,
    optcomp_cmxa: LazyPath,
    toplevel_cmxa: ?LazyPath,
    base_libs_dir: ?LazyPath,
    profiling_dir: ?LazyPath,
    lex_compiled: ?Ocamlopt.Compiled = null,
};

pub fn buildArchNative(
    src: *const Source,
    shared: Shared,
    arch_byte: ArchByte,
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
            if (u.unit.dest == .profiling) {
                _ = dest.addCopyFile(u.impl.obj, b.fmt("{s}.o", .{u.unit.name}));
            }
        }
        for ([_][]const u8{ "driver/main", "driver/optmain", "toplevel/topstart" }) |key| {
            if (compiled.impls.get(key)) |u| {
                _ = l.addCopyFile(u.impl.obj, b.fmt("{s}.o", .{u.unit.name}));
            }
        }
    }

    const bytecomp = if (frontend) |fe| fe.bytecomp_cmxa else archiveNativeLib(opt, compiled, libs, "ocamlbytecomp", cc.ocamlbytecomp);
    const middleend = if (frontend) |fe| fe.middleend_cmxa else archiveNativeLib(opt, compiled, libs, "ocamlmiddleend", cc.ocamlmiddleend);
    const optcomp = archiveNativeLib(opt, compiled, libs, "ocamloptcomp", cc.ocamloptcomp);
    const toplevel = if (libs != null) archiveNativeLib(opt, compiled, libs, "ocamltoplevel", cc.ocamltoplevel_native) else null;

    const lex_compiled: ?Ocamlopt.Compiled = if (dynlink_dir != null)
        opt.compilePlan(src.manifest.lex.plan, arch_byte.sources, shared.lex, .{ .flags = cc.compflags })
    else
        null;

    return .{
        .compiled = compiled,
        .bytecomp_cmxa = bytecomp,
        .middleend_cmxa = middleend,
        .optcomp_cmxa = optcomp,
        .toplevel_cmxa = toplevel,
        .base_libs_dir = if (libs) |l| l.getDirectory() else null,
        .profiling_dir = if (profiling) |p| p.getDirectory() else null,
        .lex_compiled = lex_compiled,
    };
}

pub fn linkOcamllexOpt(
    src: *const Source,
    arch_byte: ArchByte,
    lex: Ocamlopt.Compiled,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
) LazyPath {
    return opt.link("ocamllex.opt", lex.cmxs(src.b, src.manifest.lex.ocamllex), .{
        .includes = &.{ arch_byte.compiled.cmis_dir, rt.native_runtime_dir.?, lex.dir },
        .flags = native_link_flags,
        .strip_debug = true,
    });
}

pub const NativeCommon = struct {
    config_cmx: LazyPath,
    cmxa: LazyPath,
    lib: LazyPath,
};

pub fn buildNativeCommon(
    src: *const Source,
    arch_byte: ArchByte,
    arch_nat: ArchNative,
    config_main_ml: LazyPath,
    opt: Ocamlopt,
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

    return .{
        .config_cmx = cfg_nat.cmx,
        .cmxa = common_archive.cmxa,
        .lib = common_archive.lib,
    };
}

pub fn linkOcamloptOpt(
    arch_byte: ArchByte,
    arch_nat: ArchNative,
    nat_common: NativeCommon,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
) LazyPath {
    return opt.link("ocamlopt.opt", &.{ nat_common.cmxa, arch_nat.optcomp_cmxa, arch_nat.compiled.cmx("driver/optmain").? }, nativeLinkOpts(opt, arch_byte, arch_nat, rt));
}

/// `ocamlopt_opt` and `ocamllex_opt` are linked separately (`linkOcamloptOpt`, `linkOcamllexOpt`).
pub fn linkNativePrograms(
    arch_byte: ArchByte,
    arch_nat: ArchNative,
    nat_common: NativeCommon,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
    ocamlopt_opt: LazyPath,
    ocamllex_opt: LazyPath,
) NativePrograms {
    const opts = nativeLinkOpts(opt, arch_byte, arch_nat, rt);
    return .{
        .ocamlc = opt.link("ocamlc.opt", &.{ nat_common.cmxa, arch_nat.bytecomp_cmxa, arch_nat.compiled.cmx("driver/main").? }, opts),
        .ocamlopt = ocamlopt_opt,
        .ocamllex = ocamllex_opt,
        .ocamldep = opt.link("ocamldep.opt", &.{ nat_common.cmxa, arch_nat.bytecomp_cmxa, arch_nat.compiled.cmx("tools/ocamldep").? }, opts),
        .ocamlobjinfo = opt.link("ocamlobjinfo.opt", &.{ nat_common.cmxa, arch_nat.bytecomp_cmxa, arch_nat.middleend_cmxa, arch_nat.compiled.cmx("tools/objinfo").? }, opts),
    };
}

/// How installed bytecode programs find `ocamlrun` and the stdlib. Relocatable
/// releases are linked so nothing depends on the install prefix: the stdlib is
/// `../lib/ocaml` relative to `ocamlrun`, and the launcher looks for `ocamlrun`
/// next to the program, then on `PATH`.
pub fn launchFlags(b: *std.Build, host: Platform) []const []const u8 {
    return b.allocator.dupe([]const u8, &.{
        "-set-runtime-default",
        "standard_library_default=" ++ configure.stdlib_dir_from_bin,
        "-launch-method",
        if (host.is_windows) "exe" else "sh",
        "-runtime-search",
        "enable",
    }) catch @panic("OOM");
}

/// `boot/ocamllex`, run in the source tree on `mll` (relative to it).
const Lexer = struct {
    src: *const Source,
    ocamlrun: *std.Build.Step.Compile,

    fn run(self: Lexer, mll: []const u8) LazyPath {
        const r = self.src.b.addRunArtifact(self.ocamlrun);
        r.setCwd(self.src.path(""));
        r.addFileArg(self.src.path("boot/ocamllex"));
        r.addArgs(&.{ "-q", "-o" });
        const ml = replaceExt(self.src.b, mll, ".ml");
        const out = r.addOutputFileArg(std.fs.path.basename(ml));
        r.addFileInput(self.src.path(mll));
        r.addArg(mll);
        return self.src.nameSource(out, ml);
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

/// `ocamlyacc`, run in the source tree on `mly` (relative to it).
fn runYacc(src: *const Source, ocamlyacc: *std.Build.Step.Compile, mly: []const u8) struct { ml: LazyPath, mli: LazyPath } {
    const b = src.b;
    const run = b.addRunArtifact(ocamlyacc);
    run.setCwd(src.path(""));
    run.addArgs(&.{ "--strict", "-b" });
    const stem = replaceExt(b, mly, "");
    const prefix = run.addOutputFileArg(std.fs.path.basename(stem));
    run.addFileInput(src.path(mly));
    run.addArg(mly);
    const dir = prefix.dirname();
    return .{
        .ml = src.nameSource(dir.path(b, b.fmt("{s}.ml", .{std.fs.path.basename(stem)})), b.fmt("{s}.ml", .{stem})),
        .mli = src.nameSource(dir.path(b, b.fmt("{s}.mli", .{std.fs.path.basename(stem)})), b.fmt("{s}.mli", .{stem})),
    };
}

fn replaceExt(b: *std.Build, path: []const u8, ext: []const u8) []const u8 {
    return b.fmt("{s}{s}", .{ path[0 .. path.len - std.fs.path.extension(path).len], ext });
}

/// For the compiler's own native executables.
fn nativeLinkOpts(opt: Ocamlopt, arch_byte: ArchByte, arch_nat: ArchNative, rt: runtime.Artifacts) Ocamlopt.Options {
    return .{
        .includes = opt.b.allocator.dupe(LazyPath, &.{ arch_byte.compiled.cmis_dir, arch_nat.compiled.dir, rt.native_runtime_dir.? }) catch @panic("OOM"),
        .flags = native_link_flags,
        .strip_debug = true,
    };
}

fn archiveNativeLib(o: Ocamlopt, c: Ocamlopt.Compiled, wf: ?*std.Build.Step.WriteFile, name: []const u8, keys: []const []const u8) LazyPath {
    const a = o.archive(name, c.cmxs(o.b, keys), .{});
    if (wf) |w| {
        _ = w.addCopyFile(a.cmxa, o.b.fmt("{s}.cmxa", .{name}));
        _ = w.addCopyFile(a.lib, o.b.fmt("{s}.a", .{name}));
    }
    return a.cmxa;
}
