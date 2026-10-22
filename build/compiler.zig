const std = @import("std");
const TargetConfig = @import("target_config.zig").TargetConfig;
const SourceInfo = @import("source_info.zig").SourceInfo;
const Manifest = @import("manifests/manifest.zig");
const RuntimeArtifacts = @import("runtime.zig").RuntimeArtifacts;
const StdlibArtifacts = @import("stdlib.zig").StdlibArtifacts;
const Tools = @import("tools/root.zig");

pub const CompilerArtifacts = struct {
    ocamlc_byte: std.Build.LazyPath,
    ocamlopt_byte: std.Build.LazyPath,
    ocamllex_byte: std.Build.LazyPath,
    ocamldep_byte: std.Build.LazyPath,
    ocamlobjinfo_byte: std.Build.LazyPath,
    ocamlcmt_byte: std.Build.LazyPath,
    ocamlprof_byte: std.Build.LazyPath,
    ocamlcp_byte: std.Build.LazyPath,
    ocamloptp_byte: std.Build.LazyPath,
    ocamlmklib_byte: std.Build.LazyPath,
    ocamlmktop_byte: std.Build.LazyPath,
    expunge_byte: std.Build.LazyPath,
    ocaml_toplevel: std.Build.LazyPath,
    compilerlibs_dir: std.Build.LazyPath,
    profiling_dir: std.Build.LazyPath,
    gen_sources: GeneratedCompilerSources,

    pub fn resolveSource(
        self: CompilerArtifacts,
        b: *std.Build,
        ocaml_dep: *std.Build.Dependency,
        arch: []const u8,
        src_path: []const u8,
    ) std.Build.LazyPath {
        return self.gen_sources.resolve(b, ocaml_dep, arch, src_path);
    }
};

pub const GeneratedCompilerSources = struct {
    config_main_ml: std.Build.LazyPath,
    config_boot_ml: std.Build.LazyPath,
    domainstate_ml: std.Build.LazyPath,
    domainstate_mli: std.Build.LazyPath,
    runtimedef_ml: std.Build.LazyPath,
    menhir_lib_mli: std.Build.LazyPath,
    parser_ml: std.Build.LazyPath,
    parser_mli: std.Build.LazyPath,
    parsing_lexer_ml: std.Build.LazyPath,
    byterntm_ml: ?std.Build.LazyPath,
    opcodes_ml: std.Build.LazyPath,
    opcodes_mli: std.Build.LazyPath,
    opnames_ml: std.Build.LazyPath,
    emit_ml: std.Build.LazyPath,
    lex_parser_ml: std.Build.LazyPath,
    lex_parser_mli: std.Build.LazyPath,
    lex_lexer_ml: std.Build.LazyPath,

    pub fn resolve(
        self: GeneratedCompilerSources,
        b: *std.Build,
        ocaml_dep: *std.Build.Dependency,
        arch: []const u8,
        src_path: []const u8,
    ) std.Build.LazyPath {
        if (std.mem.startsWith(u8, src_path, "@gen/")) {
            const name = src_path["@gen/".len..];
            inline for (&.{
                .{ "config_main.ml", self.config_main_ml },
                .{ "config_boot.ml", self.config_boot_ml },
                .{ "domainstate.ml", self.domainstate_ml },
                .{ "domainstate.mli", self.domainstate_mli },
                .{ "runtimedef.ml", self.runtimedef_ml },
                .{ "camlinternalMenhirLib.mli", self.menhir_lib_mli },
                .{ "parser.ml", self.parser_ml },
                .{ "parser.mli", self.parser_mli },
                .{ "parsing_lexer.ml", self.parsing_lexer_ml },
                .{ "opcodes.ml", self.opcodes_ml },
                .{ "opcodes.mli", self.opcodes_mli },
                .{ "opnames.ml", self.opnames_ml },
                .{ "emit.ml", self.emit_ml },
                .{ "lex_parser.ml", self.lex_parser_ml },
                .{ "lex_parser.mli", self.lex_parser_mli },
                .{ "lex_lexer.ml", self.lex_lexer_ml },
            }) |entry| {
                if (std.mem.eql(u8, name, entry[0])) return entry[1];
            }
            if (std.mem.eql(u8, name, "byterntm.ml")) return self.byterntm_ml.?;
            std.debug.panic("Unknown @gen/ source: '{s}'", .{src_path});
        }
        if (std.mem.startsWith(u8, src_path, "@arch/")) {
            const name = src_path["@arch/".len..];
            return ocaml_dep.path(b.fmt("asmcomp/{s}/{s}", .{ arch, name }));
        }
        return ocaml_dep.path(src_path);
    }
};

pub const BuildCompilerOptions = struct {
    src_info: SourceInfo,
    host_cfg: TargetConfig,
    target_cfg: TargetConfig,
    target_rt: RuntimeArtifacts,
    target_stdlib: StdlibArtifacts,
    build_ocamlrun: *std.Build.Step.Compile,
    build_ocamlyacc: *std.Build.Step.Compile,
    install_bindir: []const u8,
    install_libdir: []const u8,
};

pub fn buildCompiler(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildCompilerOptions,
) !CompilerArtifacts {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const v = src_info.version;
    const host_cfg = options.host_cfg;
    const target_cfg = options.target_cfg;
    const is_intel = std.mem.eql(u8, target_cfg.arch, "amd64") or std.mem.eql(u8, target_cfg.arch, "i386");

    const is_5_5_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 5, .patch = 0 }) != .lt;
    const is_5_2_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 2, .patch = 0 }) != .lt;
    const is_5_1_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 1, .patch = 0 }) != .lt;

    // 1. Render utils/config_main.ml, utils/config_boot.ml, and compilerlibs/META
    const config_common_ml = renderConfigCommonMl(src_info, is_5_2_or_newer);
    const config_generated_ml = renderConfigGeneratedMl(b, src_info, host_cfg, target_cfg, options.install_bindir, options.install_libdir, is_5_1_or_newer);
    const config_fixed_ml = SourceInfo.readFile(b, ocaml_dep, "utils/config.fixed.ml");

    const config_main_content = b.fmt("{s}\n{s}", .{ config_generated_ml, config_common_ml });
    const config_boot_content = b.fmt("{s}\n{s}", .{ config_fixed_ml, config_common_ml });

    const compilerlibs_meta_content = src_info.renderAtTemplate("compilerlibs/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from compilerlibs/META.in" },
        .{ .name = "VERSION", .value = v.version_string },
    });

    const config_wf = b.addWriteFiles();
    const config_main_lp = config_wf.add("config_main.ml", config_main_content);
    const config_boot_lp = config_wf.add("config_boot.ml", config_boot_content);

    // 2. Run pure-Zig generator for domainstate, runtimedef, and menhir parser files
    var gen_src_cmd = Tools.Command{
        .gen_compiler_sources = .{
            .ocaml_src_dir = .of(ocaml_dep.path("")),
            .primitives = .of(options.target_rt.primitives),
            .arch64 = target_cfg.arch64,
            .domainstate_ml = .of("domainstate.ml"),
            .domainstate_mli = .of("domainstate.mli"),
            .runtimedef_ml = .of("runtimedef.ml"),
            .menhir_lib_mli = .of("camlinternalMenhirLib.mli"),
            .parser_ml = .of("parser.ml"),
            .parser_mli = .of("parser.mli"),
        },
    };
    _ = gen_src_cmd.run(b);

    // 3. Run ocamlyacc on lex/parser.mly and boot/ocamllex on .mll files via `b.addRunArtifact`
    const yacc_run = b.addRunArtifact(options.build_ocamlyacc);
    if (is_5_1_or_newer) yacc_run.addArg("--strict");
    yacc_run.addArg("-b");
    const yacc_prefix = yacc_run.addOutputFileArg("parser");
    yacc_run.addFileArg(ocaml_dep.path("lex/parser.mly"));
    const lex_parser_ml = yacc_prefix.dirname().path(b, "parser.ml");
    const lex_parser_mli = yacc_prefix.dirname().path(b, "parser.mli");

    const boot_ocamllex = ocaml_dep.path("boot/ocamllex");
    const lex_lexer_ml = runOcamllex(b, options.build_ocamlrun, boot_ocamllex, ocaml_dep.path("lex/lexer.mll"), "lexer.ml");
    const parsing_lexer_ml = runOcamllex(b, options.build_ocamlrun, boot_ocamllex, ocaml_dep.path("parsing/lexer.mll"), "lexer.ml");
    const byterntm_ml = if (is_5_2_or_newer)
        runOcamllex(b, options.build_ocamlrun, boot_ocamllex, ocaml_dep.path("bytecomp/byterntm.mll"), "byterntm.ml")
    else
        null;
    const make_opcodes_ml = runOcamllex(b, options.build_ocamlrun, boot_ocamllex, ocaml_dep.path("tools/make_opcodes.mll"), "make_opcodes.ml");
    const cvt_emit_ml = runOcamllex(b, options.build_ocamlrun, boot_ocamllex, ocaml_dep.path("tools/cvt_emit.mll"), "cvt_emit.ml");

    // 4. Compile & link tools/make_opcodes.byte and tools/cvt_emit.byte, then generate opcodes.{ml,mli}, opnames.ml, emit.ml
    const boot_ocamlc = ocaml_dep.path("boot/ocamlc");
    const primitives = options.target_rt.primitives;
    const stdlib_dir = options.target_stdlib.stdlib_dir;
    const launch_method = if (host_cfg.is_windows) "exe" else b.fmt("sh {s}", .{options.install_bindir});

    const make_opcodes_exe = compileSingleFileTool(b, options, boot_ocamlc, primitives, stdlib_dir, make_opcodes_ml, "make_opcodes", is_5_5_or_newer, launch_method);
    const cvt_emit_exe = compileSingleFileTool(b, options, boot_ocamlc, primitives, stdlib_dir, cvt_emit_ml, "cvt_emit", is_5_5_or_newer, launch_method);

    const instruct_h = ocaml_dep.path("runtime/caml/instruct.h");

    const opcodes_ml = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(make_opcodes_exe);
        run.addArg("-opcodes");
        run.setStdIn(.{ .lazy_path = instruct_h });
        break :blk run.captureStdOut(.{});
    };

    const opcodes_mli = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(boot_ocamlc);
        run.addArgs(&.{ "-nostdlib", "-I" });
        run.addDirectoryArg(stdlib_dir);
        run.addArgs(&.{ "-use-prims" });
        run.addFileArg(primitives);
        run.addArgs(&.{ "-i", "-impl" });
        run.addFileArg(opcodes_ml);
        break :blk run.captureStdOut(.{});
    };

    const opnames_ml = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(make_opcodes_exe);
        run.addArg("-opnames");
        run.setStdIn(.{ .lazy_path = instruct_h });
        break :blk run.captureStdOut(.{});
    };

    const emit_ml = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(cvt_emit_exe);
        run.setStdIn(.{ .lazy_path = ocaml_dep.path(b.fmt("asmcomp/{s}/emit.mlp", .{target_cfg.arch})) });
        const emit_body = run.captureStdOut(.{});

        var prep_cmd = Tools.Command{
            .prepend_emit_line = .{
                .cvt_emit_output = .of(emit_body),
                .arch = target_cfg.arch,
                .out_emit_ml = .of("emit.ml"),
            },
        };
        _ = prep_cmd.run(b);
        break :blk prep_cmd.prepend_emit_line.out_emit_ml.lazyPath();
    };

    const gen_sources = GeneratedCompilerSources{
        .config_main_ml = config_main_lp,
        .config_boot_ml = config_boot_lp,
        .domainstate_ml = gen_src_cmd.gen_compiler_sources.domainstate_ml.lazyPath(),
        .domainstate_mli = gen_src_cmd.gen_compiler_sources.domainstate_mli.lazyPath(),
        .runtimedef_ml = gen_src_cmd.gen_compiler_sources.runtimedef_ml.lazyPath(),
        .menhir_lib_mli = gen_src_cmd.gen_compiler_sources.menhir_lib_mli.lazyPath(),
        .parser_ml = gen_src_cmd.gen_compiler_sources.parser_ml.lazyPath(),
        .parser_mli = gen_src_cmd.gen_compiler_sources.parser_mli.lazyPath(),
        .parsing_lexer_ml = parsing_lexer_ml,
        .byterntm_ml = byterntm_ml,
        .opcodes_ml = opcodes_ml,
        .opcodes_mli = opcodes_mli,
        .opnames_ml = opnames_ml,
        .emit_ml = emit_ml,
        .lex_parser_ml = lex_parser_ml,
        .lex_parser_mli = lex_parser_mli,
        .lex_lexer_ml = lex_lexer_ml,
    };

    // 5. Schedule compiler .cmi waves and .cmo units via `b.addRunArtifact`
    const compilerlibs_wf = b.addWriteFiles();
    _ = compilerlibs_wf.add("META", compilerlibs_meta_content);
    const profiling_wf = b.addWriteFiles();

    const all_cmis_wf = b.addWriteFiles();
    var prev_wave_dirs: std.ArrayList(std.Build.LazyPath) = .empty;
    var cmi_map: std.StringHashMapUnmanaged(std.Build.LazyPath) = .empty;
    var cmo_map: std.StringHashMapUnmanaged(std.Build.LazyPath) = .empty;

    for (m.compiler_cmi_waves) |wave| {
        const wave_wf = b.addWriteFiles();
        for (wave) |u| {
            if (u.only_intel and !is_intel) continue;

            const is_tools = std.mem.startsWith(u8, u.key, "tools/");
            const is_profiling = std.mem.eql(u8, u.key, "tools/profiling");
            const src_lp = gen_sources.resolve(b, ocaml_dep, target_cfg.arch, u.src_path);

            const run = b.addRunArtifact(options.build_ocamlrun);
            run.addFileArg(boot_ocamlc);
            run.addArgs(&.{ "-nostdlib", "-I" });
            run.addDirectoryArg(stdlib_dir);
            run.addArgs(&.{"-use-prims"});
            run.addFileArg(primitives);
            run.addArgs(m.compiler_compflags);
            for (prev_wave_dirs.items) |wdir| {
                run.addArg("-I");
                run.addDirectoryArg(wdir);
            }

            if (u.is_ml_without_mli) {
                run.addArgs(&.{ "-w", "-70", "-o" });
                const cmo_lp = run.addOutputFileArg(u.cmo_name);
                run.addArgs(&.{ "-c", "-impl" });
                run.addFileArg(src_lp);

                const cmi_lp = cmo_lp.dirname().path(b, u.cmi_name);
                const cmt_name = b.fmt("{s}.cmt", .{u.cmo_name[0 .. u.cmo_name.len - 4]});
                const cmt_lp = cmo_lp.dirname().path(b, cmt_name);

                _ = wave_wf.addCopyFile(cmi_lp, u.cmi_name);
                _ = all_cmis_wf.addCopyFile(cmi_lp, u.cmi_name);
                try cmi_map.put(b.allocator, u.cmi_name, cmi_lp);
                try cmo_map.put(b.allocator, u.key, cmo_lp);

                if (!is_tools) {
                    _ = compilerlibs_wf.addCopyFile(cmi_lp, u.cmi_name);
                    _ = compilerlibs_wf.addCopyFile(cmt_lp, cmt_name);
                } else if (is_profiling) {
                    _ = profiling_wf.addCopyFile(cmi_lp, u.cmi_name);
                    _ = profiling_wf.addCopyFile(cmo_lp, u.cmo_name);
                    _ = profiling_wf.addCopyFile(cmt_lp, cmt_name);
                }
            } else {
                const stem = u.cmi_name[0 .. u.cmi_name.len - 4];
                const cmti_name = b.fmt("{s}.cmti", .{stem});
                const mli_name = b.fmt("{s}.mli", .{stem});

                run.addArg("-o");
                const cmi_lp = run.addOutputFileArg(u.cmi_name);
                run.addArgs(&.{ "-c", "-intf" });
                run.addFileArg(src_lp);

                const cmti_lp = cmi_lp.dirname().path(b, cmti_name);
                _ = wave_wf.addCopyFile(cmi_lp, u.cmi_name);
                _ = all_cmis_wf.addCopyFile(cmi_lp, u.cmi_name);
                try cmi_map.put(b.allocator, u.cmi_name, cmi_lp);

                if (!is_tools) {
                    _ = compilerlibs_wf.addCopyFile(cmi_lp, u.cmi_name);
                    _ = compilerlibs_wf.addCopyFile(cmti_lp, cmti_name);
                    _ = compilerlibs_wf.addCopyFile(src_lp, mli_name);
                } else if (is_profiling) {
                    _ = profiling_wf.addCopyFile(cmi_lp, u.cmi_name);
                    _ = profiling_wf.addCopyFile(cmti_lp, cmti_name);
                }
            }
        }
        try prev_wave_dirs.append(b.allocator, wave_wf.getDirectory());
    }

    const all_cmis_dir = all_cmis_wf.getDirectory();

    for (m.compiler_cmo_units) |u| {
        if (u.only_intel and !is_intel) continue;
        if (cmo_map.contains(u.key)) continue;

        const is_tools = std.mem.startsWith(u8, u.key, "tools/");
        const is_profiling = std.mem.eql(u8, u.key, "tools/profiling");
        const src_lp = gen_sources.resolve(b, ocaml_dep, target_cfg.arch, u.src_path);
        const stem = u.cmo_name[0 .. u.cmo_name.len - 4];
        const cmi_name = b.fmt("{s}.cmi", .{stem});

        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(boot_ocamlc);
        run.addArgs(&.{ "-nostdlib", "-I" });
        run.addDirectoryArg(stdlib_dir);
        run.addArg("-I");
        run.addDirectoryArg(all_cmis_dir);
        run.addArgs(&.{"-use-prims"});
        run.addFileArg(primitives);
        run.addArgs(m.compiler_compflags);
        run.addArgs(u.extra_flags);
        if (cmi_map.get(cmi_name)) |cmi_lp| {
            run.addArg("-cmi-file");
            run.addFileArg(cmi_lp);
        } else {
            run.addArgs(&.{ "-w", "-70" });
        }
        run.addArg("-o");

        const cmo_lp = run.addOutputFileArg(u.cmo_name);
        run.addArgs(&.{ "-c", "-impl" });
        run.addFileArg(src_lp);

        const cmt_name = b.fmt("{s}.cmt", .{stem});
        const cmt_lp = cmo_lp.dirname().path(b, cmt_name);

        try cmo_map.put(b.allocator, u.key, cmo_lp);
        if (!is_tools) {
            _ = compilerlibs_wf.addCopyFile(cmt_lp, cmt_name);
        } else if (is_profiling) {
            _ = profiling_wf.addCopyFile(cmo_lp, u.cmo_name);
            _ = profiling_wf.addCopyFile(cmt_lp, cmt_name);
        }
    }

    _ = compilerlibs_wf.addCopyFile(cmo_map.get("driver/main").?, "main.cmo");
    _ = compilerlibs_wf.addCopyFile(cmo_map.get("driver/optmain").?, "optmain.cmo");
    _ = compilerlibs_wf.addCopyFile(cmo_map.get("toplevel/topstart").?, "topstart.cmo");

    // 6. Schedule lex .cmi waves and .cmo units via `b.addRunArtifact`
    const lex_cmis_wf = b.addWriteFiles();
    var lex_prev_waves: std.ArrayList(std.Build.LazyPath) = .empty;
    var lex_cmi_map: std.StringHashMapUnmanaged(std.Build.LazyPath) = .empty;
    var lex_cmo_map: std.StringHashMapUnmanaged(std.Build.LazyPath) = .empty;

    for (m.lex_cmi_waves) |wave| {
        const wave_wf = b.addWriteFiles();
        for (wave) |u| {
            const src_lp = gen_sources.resolve(b, ocaml_dep, target_cfg.arch, u.src_path);
            const run = b.addRunArtifact(options.build_ocamlrun);
            run.addFileArg(boot_ocamlc);
            run.addArgs(&.{ "-nostdlib", "-I" });
            run.addDirectoryArg(stdlib_dir);
            run.addArgs(&.{"-use-prims"});
            run.addFileArg(primitives);
            run.addArgs(m.compiler_compflags);
            for (lex_prev_waves.items) |wdir| {
                run.addArg("-I");
                run.addDirectoryArg(wdir);
            }

            if (u.is_ml_without_mli) {
                run.addArgs(&.{ "-w", "-70", "-o" });
                const cmo_lp = run.addOutputFileArg(u.cmo_name);
                run.addArgs(&.{ "-c", "-impl" });
                run.addFileArg(src_lp);
                const cmi_lp = cmo_lp.dirname().path(b, u.cmi_name);
                _ = wave_wf.addCopyFile(cmi_lp, u.cmi_name);
                _ = lex_cmis_wf.addCopyFile(cmi_lp, u.cmi_name);
                try lex_cmi_map.put(b.allocator, u.cmi_name, cmi_lp);
                try lex_cmo_map.put(b.allocator, u.key, cmo_lp);
            } else {
                run.addArg("-o");
                const cmi_lp = run.addOutputFileArg(u.cmi_name);
                run.addArgs(&.{ "-c", "-intf" });
                run.addFileArg(src_lp);
                _ = wave_wf.addCopyFile(cmi_lp, u.cmi_name);
                _ = lex_cmis_wf.addCopyFile(cmi_lp, u.cmi_name);
                try lex_cmi_map.put(b.allocator, u.cmi_name, cmi_lp);
            }
        }
        try lex_prev_waves.append(b.allocator, wave_wf.getDirectory());
    }

    const all_lex_cmis_dir = lex_cmis_wf.getDirectory();
    for (m.lex_cmo_units) |u| {
        if (lex_cmo_map.contains(u.key)) continue;
        const src_lp = gen_sources.resolve(b, ocaml_dep, target_cfg.arch, u.src_path);
        const stem = u.cmo_name[0 .. u.cmo_name.len - 4];
        const cmi_name = b.fmt("{s}.cmi", .{stem});

        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(boot_ocamlc);
        run.addArgs(&.{ "-nostdlib", "-I" });
        run.addDirectoryArg(stdlib_dir);
        run.addArg("-I");
        run.addDirectoryArg(all_lex_cmis_dir);
        run.addArgs(&.{"-use-prims"});
        run.addFileArg(primitives);
        run.addArgs(m.compiler_compflags);
        if (lex_cmi_map.get(cmi_name)) |cmi_lp| {
            run.addArg("-cmi-file");
            run.addFileArg(cmi_lp);
        } else {
            run.addArgs(&.{ "-w", "-70" });
        }
        run.addArg("-o");
        const cmo_lp = run.addOutputFileArg(u.cmo_name);
        run.addArgs(&.{ "-c", "-impl" });
        run.addFileArg(src_lp);
        try lex_cmo_map.put(b.allocator, u.key, cmo_lp);
    }

    // 7. Link compilerlibs/*.cma
    const ocamlcommon_cma = linkCma(b, options, boot_ocamlc, primitives, stdlib_dir, "ocamlcommon.cma", m.ocamlcommon_cmos, &cmo_map, is_intel, &.{"-linkall"});
    const ocamlbytecomp_cma = linkCma(b, options, boot_ocamlc, primitives, stdlib_dir, "ocamlbytecomp.cma", m.ocamlbytecomp_cmos, &cmo_map, is_intel, &.{});
    const ocamlmiddleend_cma = linkCma(b, options, boot_ocamlc, primitives, stdlib_dir, "ocamlmiddleend.cma", m.ocamlmiddleend_cmos, &cmo_map, is_intel, &.{});
    const ocamloptcomp_cma = linkCma(b, options, boot_ocamlc, primitives, stdlib_dir, "ocamloptcomp.cma", m.ocamloptcomp_cmos, &cmo_map, is_intel, &.{});
    const ocamltoplevel_cma = linkCma(b, options, boot_ocamlc, primitives, stdlib_dir, "ocamltoplevel.cma", m.ocamltoplevel_cmos, &cmo_map, is_intel, &.{});

    _ = compilerlibs_wf.addCopyFile(ocamlcommon_cma, "ocamlcommon.cma");
    _ = compilerlibs_wf.addCopyFile(ocamlbytecomp_cma, "ocamlbytecomp.cma");
    _ = compilerlibs_wf.addCopyFile(ocamlmiddleend_cma, "ocamlmiddleend.cma");
    _ = compilerlibs_wf.addCopyFile(ocamloptcomp_cma, "ocamloptcomp.cma");
    _ = compilerlibs_wf.addCopyFile(ocamltoplevel_cma, "ocamltoplevel.cma");

    // 8. Link bytecode compilers and tools
    const ocamlc_byte = linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlc.byte", &.{ ocamlcommon_cma, ocamlbytecomp_cma, cmo_map.get("driver/main").? }, &.{ "-compat-32", "-g" }, is_5_5_or_newer, launch_method);
    const ocamlopt_byte = linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlopt.byte", &.{ ocamlcommon_cma, ocamloptcomp_cma, cmo_map.get("driver/optmain").? }, &.{"-g"}, is_5_5_or_newer, launch_method);
    const ocamllex_byte = linkProgramFromKeys(b, options, boot_ocamlc, primitives, stdlib_dir, all_lex_cmis_dir, "ocamllex.byte", m.ocamllex_cmos, &lex_cmo_map, &.{"-compat-32"}, is_5_5_or_newer, launch_method);
    const expunge_byte = linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "expunge.byte", &.{ ocamlcommon_cma, ocamlbytecomp_cma, cmo_map.get("toplevel/expunge").? }, &.{}, is_5_5_or_newer, launch_method);
    const ocamldep_byte = linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamldep.byte", &.{ ocamlcommon_cma, ocamlbytecomp_cma, cmo_map.get("tools/ocamldep").? }, &.{"-compat-32"}, is_5_5_or_newer, launch_method);
    const ocamlobjinfo_byte = linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlobjinfo.byte", &.{ ocamlcommon_cma, ocamlbytecomp_cma, ocamlmiddleend_cma, cmo_map.get("tools/objinfo").? }, &.{}, is_5_5_or_newer, launch_method);
    const ocamlcmt_byte = linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlcmt.byte", &.{ ocamlcommon_cma, ocamlbytecomp_cma, cmo_map.get("tools/ocamlcmt").? }, &.{}, is_5_5_or_newer, launch_method);
    const ocamlprof_byte = linkProgramFromKeys(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlprof.byte", m.ocamlprof_cmos, &cmo_map, &.{}, is_5_5_or_newer, launch_method);
    const ocamlcp_byte = linkProgramFromKeys(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlcp.byte", m.ocamlcp_cmos, &cmo_map, &.{}, is_5_5_or_newer, launch_method);
    const ocamloptp_byte = linkProgramFromKeys(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamloptp.byte", m.ocamloptp_cmos, &cmo_map, &.{}, is_5_5_or_newer, launch_method);
    const ocamlmklib_byte = linkProgramFromKeys(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlmklib.byte", m.ocamlmklib_cmos, &cmo_map, &.{}, is_5_5_or_newer, launch_method);
    const ocamlmktop_byte = linkProgramFromKeys(b, options, boot_ocamlc, primitives, stdlib_dir, all_cmis_dir, "ocamlmktop.byte", m.ocamlmktop_cmos, &cmo_map, &.{}, is_5_5_or_newer, launch_method);

    // 9. Link ocaml.tmp and expunge to produce ocaml toplevel
    const ocaml_tmp = linkProgram(
        b,
        options,
        boot_ocamlc,
        primitives,
        stdlib_dir,
        all_cmis_dir,
        "ocaml.tmp",
        &.{ ocamlcommon_cma, ocamlbytecomp_cma, ocamltoplevel_cma, cmo_map.get("toplevel/topstart").? },
        &.{ "-linkall", "-g" },
        is_5_5_or_newer,
        launch_method,
    );

    const ocaml_toplevel = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(expunge_byte);
        run.addFileArg(ocaml_tmp);
        const out_lp = run.addOutputFileArg("ocaml");
        run.addArgs(m.pervasives_modules);
        break :blk out_lp;
    };

    return .{
        .ocamlc_byte = ocamlc_byte,
        .ocamlopt_byte = ocamlopt_byte,
        .ocamllex_byte = ocamllex_byte,
        .ocamldep_byte = ocamldep_byte,
        .ocamlobjinfo_byte = ocamlobjinfo_byte,
        .ocamlcmt_byte = ocamlcmt_byte,
        .ocamlprof_byte = ocamlprof_byte,
        .ocamlcp_byte = ocamlcp_byte,
        .ocamloptp_byte = ocamloptp_byte,
        .ocamlmklib_byte = ocamlmklib_byte,
        .ocamlmktop_byte = ocamlmktop_byte,
        .expunge_byte = expunge_byte,
        .ocaml_toplevel = ocaml_toplevel,
        .compilerlibs_dir = compilerlibs_wf.getDirectory(),
        .profiling_dir = profiling_wf.getDirectory(),
        .gen_sources = gen_sources,
    };
}

fn runOcamllex(
    b: *std.Build,
    build_ocamlrun: *std.Build.Step.Compile,
    boot_ocamllex: std.Build.LazyPath,
    src_mll: std.Build.LazyPath,
    out_name: []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(build_ocamlrun);
    run.addFileArg(boot_ocamllex);
    run.addArgs(&.{ "-q", "-o" });
    const out_lp = run.addOutputFileArg(out_name);
    run.addFileArg(src_mll);
    return out_lp;
}

fn compileSingleFileTool(
    b: *std.Build,
    options: BuildCompilerOptions,
    boot_ocamlc: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    stdlib_dir: std.Build.LazyPath,
    src_ml: std.Build.LazyPath,
    name: []const u8,
    has_set_runtime_default: bool,
    launch_method: []const u8,
) std.Build.LazyPath {
    const comp_run = b.addRunArtifact(options.build_ocamlrun);
    comp_run.addFileArg(boot_ocamlc);
    comp_run.addArgs(&.{ "-nostdlib", "-I" });
    comp_run.addDirectoryArg(stdlib_dir);
    comp_run.addArgs(&.{"-use-prims"});
    comp_run.addFileArg(primitives);
    comp_run.addArgs(&.{ "-w", "-70", "-o" });
    const cmo_lp = comp_run.addOutputFileArg(b.fmt("{s}.cmo", .{name}));
    comp_run.addArgs(&.{ "-c", "-impl" });
    comp_run.addFileArg(src_ml);

    const link_run = b.addRunArtifact(options.build_ocamlrun);
    link_run.addFileArg(boot_ocamlc);
    link_run.addArgs(&.{ "-nostdlib", "-I" });
    link_run.addDirectoryArg(stdlib_dir);
    link_run.addArgs(&.{"-use-prims"});
    link_run.addFileArg(primitives);
    if (has_set_runtime_default) {
        link_run.addArgs(&.{
            "-launch-method",
            launch_method,
            "-runtime-search",
            "fallback",
        });
    }
    link_run.addArg("-o");
    const exe_lp = link_run.addOutputFileArg(b.fmt("{s}.byte", .{name}));
    link_run.addFileArg(cmo_lp);
    return exe_lp;
}

fn linkCma(
    b: *std.Build,
    options: BuildCompilerOptions,
    boot_ocamlc: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    stdlib_dir: std.Build.LazyPath,
    cma_name: []const u8,
    keys: []const []const u8,
    cmo_map: *const std.StringHashMapUnmanaged(std.Build.LazyPath),
    is_intel: bool,
    extra_flags: []const []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(options.build_ocamlrun);
    run.addFileArg(boot_ocamlc);
    run.addArgs(&.{ "-nostdlib", "-I" });
    run.addDirectoryArg(stdlib_dir);
    run.addArgs(&.{"-use-prims"});
    run.addFileArg(primitives);
    run.addArgs(extra_flags);
    run.addArgs(&.{ "-a", "-o" });
    const cma_lp = run.addOutputFileArg(cma_name);
    for (keys) |k| {
        if (!is_intel and std.mem.startsWith(u8, k, "asmcomp/x86_")) continue;
        run.addFileArg(cmo_map.get(k).?);
    }
    return cma_lp;
}

fn linkProgram(
    b: *std.Build,
    options: BuildCompilerOptions,
    boot_ocamlc: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    stdlib_dir: std.Build.LazyPath,
    cmi_dir: std.Build.LazyPath,
    exe_name: []const u8,
    objs: []const std.Build.LazyPath,
    extra_flags: []const []const u8,
    has_set_runtime_default: bool,
    launch_method: []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(options.build_ocamlrun);
    run.addFileArg(boot_ocamlc);
    run.addArgs(&.{ "-nostdlib", "-I" });
    run.addDirectoryArg(stdlib_dir);
    run.addArg("-I");
    run.addDirectoryArg(cmi_dir);
    run.addArgs(&.{"-use-prims"});
    run.addFileArg(primitives);
    if (has_set_runtime_default) {
        run.addArgs(&.{
            "-set-runtime-default",
            "standard_library_default=../lib/ocaml",
            "-launch-method",
            launch_method,
            "-runtime-search",
            "fallback",
        });
    }
    run.addArgs(extra_flags);
    run.addArg("-o");
    const exe_lp = run.addOutputFileArg(exe_name);
    for (objs) |obj| {
        run.addFileArg(obj);
    }
    return exe_lp;
}

fn linkProgramFromKeys(
    b: *std.Build,
    options: BuildCompilerOptions,
    boot_ocamlc: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    stdlib_dir: std.Build.LazyPath,
    cmi_dir: std.Build.LazyPath,
    exe_name: []const u8,
    keys: []const []const u8,
    cmo_map: *const std.StringHashMapUnmanaged(std.Build.LazyPath),
    extra_flags: []const []const u8,
    has_set_runtime_default: bool,
    launch_method: []const u8,
) std.Build.LazyPath {
    var objs = b.allocator.alloc(std.Build.LazyPath, keys.len) catch @panic("OOM");
    for (keys, 0..) |k, i| {
        objs[i] = cmo_map.get(k).?;
    }
    return linkProgram(b, options, boot_ocamlc, primitives, stdlib_dir, cmi_dir, exe_name, objs, extra_flags, has_set_runtime_default, launch_method);
}

fn renderConfigCommonMl(src_info: SourceInfo, is_5_2_or_newer: bool) []const u8 {
    if (!is_5_2_or_newer) {
        return SourceInfo.readFile(src_info.b, src_info.dep, "utils/config.common.ml");
    }

    const mn = src_info.manifest.magic_numbers.?;
    return src_info.renderAtTemplate("utils/config.common.ml.in", &.{
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

fn renderConfigGeneratedMl(
    b: *std.Build,
    src_info: SourceInfo,
    host_cfg: TargetConfig,
    target_cfg: TargetConfig,
    install_bindir: []const u8,
    install_libdir: []const u8,
    is_5_1_or_newer: bool,
) []const u8 {
    const cflags = if (target_cfg.is_windows)
        "-O2 -fno-strict-aliasing -fwrapv -mms-bitfields"
    else
        "-O2 -fno-strict-aliasing -fwrapv -pthread";

    const cppflags = if (target_cfg.is_windows)
        "-D__USE_MINGW_ANSI_STDIO=0 -DUNICODE -D_UNICODE -DWINDOWS_UNICODE=1"
    else
        "-D_FILE_OFFSET_BITS=64";

    const cclibs = if (target_cfg.is_windows)
        "-lws2_32 -ladvapi32 -lole32 -luuid -lversion -lshlwapi -lapi-ms-win-core-synch-l1-2-0"
    else if (target_cfg.is_linux)
        "-lm -ldl -lpthread"
    else
        "-lm -lpthread";

    const rpath = if (target_cfg.is_elf) "-Wl,-rpath," else "";
    const native_ldflags = if (target_cfg.is_macos and std.mem.eql(u8, target_cfg.arch, "amd64"))
        "-Wl,-no_compact_unwind"
    else
        "";
    const mkdll_exp = if (target_cfg.is_macos)
        "cc -shared -undefined dynamic_lookup -Wl,-w"
    else
        "cc -shared";
    const mkexe_exp = if (target_cfg.is_elf)
        "cc -O2 -fno-strict-aliasing -fwrapv -Wl,-E"
    else
        "cc -O2 -fno-strict-aliasing -fwrapv";

    const exe_ext = if (target_cfg.is_windows) ".exe" else "";
    const so_ext = if (target_cfg.is_windows) "dll" else "so";
    const has_native = if (target_cfg.runtimeAsmFile() != null) "true" else "false";
    const align_32 = if (!target_cfg.arch64) "true" else "false";

    if (!is_5_1_or_newer) {
        return src_info.renderPercentTemplate("utils/config.mlp", &.{
            .{ .name = "BINDIR", .value = install_bindir },
            .{ .name = "LIBDIR", .value = install_libdir },
            .{ .name = "CCOMPTYPE", .value = "cc" },
            .{ .name = "CC", .value = "cc" },
            .{ .name = "OUTPUTOBJ", .value = "-o " },
            .{ .name = "CC_HAS_DEBUG_PREFIX_MAP", .value = "true" },
            .{ .name = "AS_HAS_DEBUG_PREFIX_MAP", .value = "true" },
            .{ .name = "OCAMLC_CFLAGS", .value = cflags },
            .{ .name = "OCAMLC_CPPFLAGS", .value = cppflags },
            .{ .name = "OCAMLOPT_CPPFLAGS", .value = cppflags },
            .{ .name = "BYTECCLIBS", .value = cclibs },
            .{ .name = "NATIVECCLIBS", .value = cclibs },
            .{ .name = "PACKLD", .value = "ld -r -o " },
            .{ .name = "RPATH", .value = rpath },
            .{ .name = "MKSHAREDLIBRPATH", .value = rpath },
            .{ .name = "ARCMD", .value = "ar" },
            .{ .name = "SUPPORTS_SHARED_LIBRARIES", .value = "true" },
            .{ .name = "FLEXDLL_CHAIN", .value = if (target_cfg.is_windows) "mingw64" else "" },
            .{ .name = "FLEXLINK_FLAGS", .value = if (target_cfg.is_windows) "-stack 33554432" else "" },
            .{ .name = "FLEXLINK_DLL_LDFLAGS", .value = "" },
            .{ .name = "FLEXLINK_LDFLAGS", .value = if (target_cfg.is_windows) " -link -municode" else "" },
            .{ .name = "MKDLL_EXP", .value = mkdll_exp },
            .{ .name = "MKEXE_EXP", .value = mkexe_exp },
            .{ .name = "MKMAINDLL", .value = mkdll_exp },
            .{ .name = "FLAMBDA", .value = "false" },
            .{ .name = "WITH_FLAMBDA_INVARIANTS", .value = "false" },
            .{ .name = "WITH_CMM_INVARIANTS", .value = "false" },
            .{ .name = "WINDOWS_UNICODE", .value = if (target_cfg.is_windows) "1" else "0" },
            .{ .name = "FLAT_FLOAT_ARRAY", .value = "true" },
            .{ .name = "FUNCTION_SECTIONS", .value = if (target_cfg.is_elf) "true" else "false" },
            .{ .name = "AFL_INSTRUMENT", .value = "false" },
            .{ .name = "ARCH", .value = target_cfg.arch },
            .{ .name = "MODEL", .value = target_cfg.model },
            .{ .name = "SYSTEM", .value = target_cfg.system },
            .{ .name = "ASM", .value = "cc -c" },
            .{ .name = "ASM_CFI_SUPPORTED", .value = if (!target_cfg.is_windows) "true" else "false" },
            .{ .name = "WITH_FRAME_POINTERS", .value = "false" },
            .{ .name = "WITH_PROFINFO", .value = "false" },
            .{ .name = "PROFINFO_WIDTH", .value = "0" },
            .{ .name = "EXE", .value = exe_ext },
            .{ .name = "EXT_OBJ", .value = ".o" },
            .{ .name = "EXT_ASM", .value = ".s" },
            .{ .name = "EXT_LIB", .value = ".a" },
            .{ .name = "EXT_DLL", .value = b.fmt(".{s}", .{so_ext}) },
            .{ .name = "HOST", .value = host_cfg.triplet },
            .{ .name = "TARGET", .value = target_cfg.triplet },
            .{ .name = "SYSTHREAD_SUPPORT", .value = "true" },
            .{ .name = "FLEXDLL_DIR", .value = "" },
        });
    }

    return src_info.renderAtTemplate("utils/config.generated.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from utils/config.generated.ml.in" },
        .{ .name = "QS", .value = "" },
        .{ .name = "ocaml_bindir", .value = install_bindir },
        .{ .name = "TARGET_BINDIR", .value = install_bindir, .version_specific = true },
        .{ .name = "ocaml_libdir", .value = install_libdir, .version_specific = true },
        .{ .name = "ccomptype", .value = "cc", .version_specific = true },
        .{ .name = "ccomp_type", .value = "cc", .version_specific = true },
        .{ .name = "CC", .value = "cc" },
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
        .{ .name = "with_nonexecstack_note", .value = if (target_cfg.is_linux and target_cfg.is_elf) "true" else "false", .version_specific = true },
        .{ .name = "PACKLD", .value = "ld -r -o " },
        .{ .name = "rpath", .value = rpath },
        .{ .name = "mksharedlibrpath", .value = rpath },
        .{ .name = "AR", .value = "ar" },
        .{ .name = "supports_shared_libraries", .value = "true" },
        .{ .name = "natdynlink", .value = "true" },
        .{ .name = "mkdll_exp", .value = mkdll_exp },
        .{ .name = "mkexe_exp", .value = mkexe_exp },
        .{ .name = "mkmaindll_exp", .value = mkdll_exp },
        .{ .name = "flexdll_chain", .value = if (target_cfg.is_windows) "mingw64" else "", .version_specific = true },
        .{ .name = "flexlink_flags", .value = if (target_cfg.is_windows) "-stack 33554432" else "", .version_specific = true },
        .{ .name = "mkdll_ldflags_exp", .value = "", .version_specific = true },
        .{ .name = "mkexe_extra_flags", .value = if (target_cfg.is_windows) "-link -municode" else "", .version_specific = true },
        .{ .name = "mkexe_ldflags_exp", .value = "", .version_specific = true },
        .{ .name = "flambda", .value = "false" },
        .{ .name = "flambda_invariants", .value = "false" },
        .{ .name = "cmm_invariants", .value = "false" },
        .{ .name = "codegen_invariants", .value = "false", .version_specific = true },
        .{ .name = "windows_unicode", .value = if (target_cfg.is_windows) "1" else "0" },
        .{ .name = "flat_float_array", .value = "true" },
        .{ .name = "align_double", .value = align_32, .version_specific = true },
        .{ .name = "align_int64", .value = align_32, .version_specific = true },
        .{ .name = "function_sections", .value = if (target_cfg.is_elf) "true" else "false" },
        .{ .name = "afl", .value = "false" },
        .{ .name = "bytecode_runtime_id", .value = target_cfg.bytecode_runtime_id, .version_specific = true },
        .{ .name = "native_runtime_id", .value = target_cfg.native_runtime_id, .version_specific = true },
        .{ .name = "native_compiler", .value = has_native },
        .{ .name = "arch", .value = target_cfg.arch },
        .{ .name = "model", .value = target_cfg.model },
        .{ .name = "system", .value = target_cfg.system },
        .{ .name = "target_os_type", .value = target_cfg.os_type, .version_specific = true },
        .{ .name = "AS", .value = "cc -c" },
        .{ .name = "asm_cfi_supported", .value = if (!target_cfg.is_windows) "true" else "false" },
        .{ .name = "asm_size_type_directives", .value = if (target_cfg.is_elf) "true" else "false", .version_specific = true },
        .{ .name = "asm_dwarf_version", .value = "None", .version_specific = true },
        .{ .name = "frame_pointers", .value = "false" },
        .{ .name = "reserved_header_bits", .value = "0" },
        .{ .name = "exeext", .value = exe_ext, .version_specific = true },
        .{ .name = "EXEEXT", .value = exe_ext, .version_specific = true },
        .{ .name = "OBJEXT", .value = "o" },
        .{ .name = "S", .value = "s" },
        .{ .name = "libext", .value = "a" },
        .{ .name = "SO", .value = so_ext },
        .{ .name = "host", .value = host_cfg.triplet },
        .{ .name = "target", .value = target_cfg.triplet },
        .{ .name = "systhread_support", .value = "true" },
        .{ .name = "flexdll_dir", .value = "" },
        .{ .name = "ar_supports_response_files", .value = "true" },
        .{ .name = "tsan", .value = "false", .version_specific = true },
        .{ .name = "shebangscripts", .value = if (host_cfg.is_windows) "false" else "true", .version_specific = true },
        .{ .name = "suffixing", .value = "false", .version_specific = true },
        .{ .name = "launch_method_target", .value = if (target_cfg.is_windows) "exe" else "sh", .version_specific = true },
        .{ .name = "runtime_search_target", .value = "fallback", .version_specific = true },
    });
}
