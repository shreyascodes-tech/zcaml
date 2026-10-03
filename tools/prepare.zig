const std = @import("std");
const Io = std.Io;
const Manifest = @import("manifest.zig");
const SourceGroup = Manifest.SourceGroup;
const BackendSources = Manifest.BackendSources;
const GeneratedFile = Manifest.GeneratedFile;
const Dependency = Manifest.Dependency;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len != 4) {
        std.log.err("usage: prepare-ocaml <ocaml-source-dir> <zig-source-hash> <manifest.zon>", .{});
        return error.InvalidArguments;
    }

    const root = argv[1];
    try verifyCompflags(gpa, io, root);

    const version_file = try readSource(gpa, io, root, "VERSION");
    const version = std.mem.trim(u8, std.mem.sliceTo(version_file, '\n'), " \t\r");
    const version_macros = try readSource(gpa, io, root, "build-aux/ocaml_version.m4");

    const root_make = try readSource(gpa, io, root, "Makefile");
    var make_vars = try parseMakeVariables(gpa, root_make);
    const sources = try collectSourceGroups(gpa, io, root, &make_vars);
    const backends = try collectBackends(gpa, io, root, &make_vars);
    const dependencies = try collectDependencies(gpa, io, root);
    const stdlib_modules = try collectStdlibModules(gpa, io, root);
    const generated = try collectGeneratedFiles(gpa, io, root, sources, backends);
    const compiler_modules = try collectCompilerModules(gpa, sources, generated);
    const archives = try collectArchives(gpa, stdlib_modules, compiler_modules);

    const release_number = try std.fmt.parseInt(
        u32,
        try m4Define(version_macros, "OCAML__RELEASE_NUMBER"),
        10,
    );
    const manifest: Manifest = .{
        .ocaml_version = version,
        .release_number = release_number,
        .magic_prefix = try m4Define(version_macros, "MAGIC_NUMBER__PREFIX"),
        .magic_version = try m4Define(version_macros, "MAGIC_NUMBER__VERSION"),
        .exec_format = try m4Define(version_macros, "EXEC__FORMAT"),
        .source_hash = argv[2],
        .source_groups = sources,
        .backend_sources = backends,
        .generated_files = generated,
        .dependencies = dependencies,
        .stdlib_modules = stdlib_modules,
        .compiler_modules = compiler_modules,
        .archives = archives,
    };

    try writeManifest(io, argv[3], manifest);
    std.log.info("prepared OCaml {s}: {d} source groups, {d} dependency rules, {d} generated-file rules", .{
        version, sources.len, dependencies.len, generated.len,
    });
}

fn collectCompilerModules(
    allocator: Allocator,
    groups: []const SourceGroup,
    generated: []const GeneratedFile,
) ![]const Manifest.CompilerModule {
    var modules: std.ArrayList(Manifest.CompilerModule) = .empty;

    for ([_][]const u8{ "ocamlcommon", "ocamlbytecomp", "ocamlc", "ocamlmiddleend" }) |group_name| {
        const files = sourceGroupFiles(groups, group_name);

        for (files) |file| {
            const suffix = std.fs.path.extension(file);
            if (!std.mem.eql(u8, suffix, ".ml") and
                !std.mem.eql(u8, suffix, ".mll") and
                !std.mem.eql(u8, suffix, ".mly") and
                !std.mem.eql(u8, suffix, ".mli")) continue;

            const stem = file[0 .. file.len - suffix.len];
            if (std.mem.eql(u8, suffix, ".mli")) {
                var has_implementation = false;
                for (files) |candidate| {
                    if (std.mem.startsWith(u8, candidate, stem) and
                        (std.mem.eql(u8, candidate[stem.len..], ".ml") or
                            std.mem.eql(u8, candidate[stem.len..], ".mll") or
                            std.mem.eql(u8, candidate[stem.len..], ".mly")))
                    {
                        has_implementation = true;
                        break;
                    }
                }
                if (has_implementation) continue;
            }

            const implementation: ?[]const u8 = if (std.mem.eql(u8, suffix, ".mli"))
                null
            else
                try std.fmt.allocPrint(allocator, "{s}.ml", .{stem});
            const interface_path = try std.fmt.allocPrint(allocator, "{s}.mli", .{stem});
            var has_interface = std.mem.eql(u8, suffix, ".mli");
            for (files) |candidate| {
                if (std.mem.eql(u8, candidate, interface_path)) has_interface = true;
            }
            for (generated) |rule| {
                if (std.mem.eql(u8, rule.output, interface_path)) has_interface = true;
            }

            try modules.append(allocator, .{
                .stem = stem,
                .implementation = implementation,
                .interface = if (has_interface) interface_path else null,
                .archive = if (std.mem.eql(u8, group_name, "ocamlcommon") or
                    std.mem.eql(u8, group_name, "ocamlbytecomp")) group_name else null,
                .install_interface = std.mem.eql(u8, group_name, "ocamlcommon") or
                    std.mem.eql(u8, group_name, "ocamlbytecomp"),
            });
        }
    }

    return modules.toOwnedSlice(allocator);
}

fn collectArchives(
    allocator: Allocator,
    stdlib: []const Manifest.StdlibModule,
    compiler: []const Manifest.CompilerModule,
) ![]const Manifest.Archive {
    var archives: std.ArrayList(Manifest.Archive) = .empty;
    var stdlib_members: std.ArrayList([]const u8) = .empty;
    for (stdlib) |module| {
        if (module.archive_member) {
            const stem = try std.fmt.allocPrint(allocator, "stdlib/{s}", .{module.output});
            try stdlib_members.append(allocator, stem);
        }
    }
    try archives.append(allocator, .{
        .name = "stdlib",
        .members = try stdlib_members.toOwnedSlice(allocator),
    });

    for ([_][]const u8{ "ocamlcommon", "ocamlbytecomp" }) |name| {
        var members: std.ArrayList([]const u8) = .empty;
        for (compiler) |module| {
            if (module.archive) |archive| {
                if (std.mem.eql(u8, archive, name) and module.implementation != null) {
                    try members.append(allocator, module.stem);
                }
            }
        }
        try archives.append(allocator, .{
            .name = name,
            .members = try members.toOwnedSlice(allocator),
            .link_all = std.mem.eql(u8, name, "ocamlcommon"),
        });
    }

    return archives.toOwnedSlice(allocator);
}

/// Reviewed bytecode cases of stdlib/Compflags for OCaml 5.5.1. This is
/// deliberately not a shell-case interpreter: a changed upstream file must be
/// reviewed alongside collectStdlibModules and this fingerprint.
fn verifyCompflags(gpa: Allocator, io: Io, root: []const u8) !void {
    const source = try readSource(gpa, io, root, "stdlib/Compflags");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});

    const reviewed_digest = "005b2361cf9befdad4e1d4136cbec050a9be51c97e5aa387c077e3a2e8185a1f";
    const actual_digest = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_digest, reviewed_digest)) {
        std.log.err("stdlib/Compflags changed: review bytecode flag rules in tools/prepare.zig before regenerating manifest", .{});
        return error.UnreviewedStdlibCompflags;
    }
}

fn m4Define(source: []const u8, name: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "m4_define(")) continue;
        const definition = line["m4_define(".len..];
        const key = if (std.mem.startsWith(u8, definition, "["))
            std.mem.sliceTo(definition[1..], ']')
        else
            std.mem.sliceTo(definition, ',');
        if (!std.mem.eql(u8, key, name)) continue;
        const comma = std.mem.indexOfScalar(u8, definition, ',') orelse return error.InvalidVersionMacro;
        const value_start = std.mem.indexOfScalarPos(u8, definition, comma, '[') orelse return error.InvalidVersionMacro;
        const value_end = std.mem.indexOfScalarPos(u8, definition, value_start, ']') orelse return error.InvalidVersionMacro;
        return definition[value_start + 1 .. value_end];
    }
    return error.MissingVersionMacro;
}

fn collectSourceGroups(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    make_vars: *std.StringHashMap([]const u8),
) ![]const SourceGroup {
    // These sources are supplied by the target profile, not the common groups.
    try make_vars.put("arch_specific_SOURCES", "");
    try make_vars.put("TSAN_NATIVE_RUNTIME_C_SOURCES", "");
    try make_vars.put("UNIX_OR_WIN32", "");

    var sources: std.ArrayList(SourceGroup) = .empty;
    const SourceVariable = struct {
        name: []const u8,
        variable: []const u8,
        c_prefix: ?[]const u8 = null,
    };
    const source_vars = [_]SourceVariable{
        .{ .name = "ocamlcommon", .variable = "ocamlcommon_SOURCES" },
        .{ .name = "ocamlbytecomp", .variable = "ocamlbytecomp_SOURCES" },
        .{ .name = "ocamlmiddleend", .variable = "ocamlmiddleend_SOURCES" },
        .{ .name = "ocamloptcomp", .variable = "ocamloptcomp_SOURCES" },
        .{ .name = "ocamltoplevel", .variable = "ocamltoplevel_SOURCES" },
        .{ .name = "ocamlc", .variable = "ocamlc_SOURCES" },
        .{ .name = "ocamlopt", .variable = "ocamlopt_SOURCES" },
        .{ .name = "ocaml", .variable = "ocaml_SOURCES" },
        .{ .name = "ocamllex", .variable = "ocamllex_SOURCES" },
        .{ .name = "ocamlyacc", .variable = "ocamlyacc_OTHER_MODULES", .c_prefix = "" },
        .{ .name = "ocamldep", .variable = "ocamldep_SOURCES" },
        .{ .name = "dynlink", .variable = "dynlink_SOURCES" },
        .{ .name = "cvt_emit", .variable = "cvt_emit_SOURCES" },
        .{ .name = "make_opcodes", .variable = "make_opcodes_SOURCES" },
        .{ .name = "runtime_common", .variable = "runtime_COMMON_C_SOURCES", .c_prefix = "runtime/" },
        .{ .name = "runtime_bytecode_only", .variable = "runtime_BYTECODE_ONLY_C_SOURCES", .c_prefix = "runtime/" },
        .{ .name = "runtime_native_only", .variable = "runtime_NATIVE_ONLY_C_SOURCES", .c_prefix = "runtime/" },
    };
    for (source_vars) |entry| {
        const expression = make_vars.get(entry.variable) orelse {
            std.log.err("OCaml Makefile is missing {s}", .{entry.variable});
            return error.UnsupportedSourceLayout;
        };
        const expanded = try expandMakeExpression(gpa, make_vars, expression, 0);
        var files: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, expanded, " \t\r\n");
        while (tokens.next()) |token| {
            const path = if (entry.c_prefix) |prefix|
                try std.fmt.allocPrint(gpa, "{s}{s}.c", .{ prefix, token })
            else
                token;
            try files.append(gpa, path);
        }
        if (files.items.len == 0) {
            return error.EmptySourceGroup;
        }

        try sources.append(gpa, .{ .name = entry.name, .files = try files.toOwnedSlice(gpa) });
    }
    try sources.append(gpa, .{ .name = "runtime_platform_unix", .files = &.{"runtime/unix.c"} });
    try sources.append(gpa, .{ .name = "runtime_platform_win32", .files = &.{"runtime/win32.c"} });
    try sources.append(gpa, .{ .name = "ocamlyacc_win32", .files = &.{"yacc/wstr.c"} });

    const stdlib_make = try readSource(gpa, io, root, "stdlib/StdlibModules");
    const stdlib_vars = try parseMakeVariables(gpa, stdlib_make);
    const modules = stdlib_vars.get("STDLIB_MODULE_BASENAMES") orelse return error.MissingStdlibModules;
    var stdlib_files: std.ArrayList([]const u8) = .empty;
    var module_it = std.mem.tokenizeAny(u8, modules, " \t\r\n");
    while (module_it.next()) |name| {
        const ml = try std.fmt.allocPrint(gpa, "stdlib/{s}.ml", .{name});
        const mli = try std.fmt.allocPrint(gpa, "stdlib/{s}.mli", .{name});
        const template = try std.fmt.allocPrint(gpa, "{s}.in", .{ml});
        if (try existsSource(gpa, io, root, mli)) {
            try stdlib_files.append(gpa, mli);
        }
        if (try existsSource(gpa, io, root, ml) or try existsSource(gpa, io, root, template)) {
            try stdlib_files.append(gpa, ml);
        } else {
            return error.MissingStdlibSource;
        }
    }
    try sources.append(gpa, .{ .name = "stdlib", .files = try stdlib_files.toOwnedSlice(gpa) });
    return sources.toOwnedSlice(gpa);
}

fn collectBackends(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    make_vars: *const std.StringHashMap([]const u8),
) ![]const BackendSources {
    var backends: std.ArrayList(BackendSources) = .empty;
    const backend_files = [_][]const u8{
        "arch.mli",      "arch.ml",   "proc.ml",       "CSE.ml",   "selection.ml",
        "scheduling.ml", "reload.ml", "stackframe.ml", "emit.mlp",
    };
    const arches = make_vars.get("ARCHES") orelse return error.MissingBackends;
    var arch_it = std.mem.tokenizeAny(u8, arches, " \t\r\n");
    while (arch_it.next()) |arch| {
        var paths: std.ArrayList([]const u8) = .empty;
        for (backend_files) |file| {
            const path = try std.fmt.allocPrint(gpa, "asmcomp/{s}/{s}", .{ arch, file });
            if (!try existsSource(gpa, io, root, path)) {
                return error.MissingBackendSource;
            }
            try paths.append(gpa, path);
        }
        var assembly: std.ArrayList([]const u8) = .empty;
        const asm_path = try std.fmt.allocPrint(gpa, "runtime/{s}.S", .{arch});
        if (try existsSource(gpa, io, root, asm_path)) try assembly.append(gpa, asm_path);
        if (std.mem.eql(u8, arch, "amd64")) {
            if (!try existsSource(gpa, io, root, "runtime/amd64nt.asm")) {
                return error.MissingBackendSource;
            }
            try assembly.append(gpa, "runtime/amd64nt.asm");
        }
        try backends.append(gpa, .{
            .arch = arch,
            .files = try paths.toOwnedSlice(gpa),
            .runtime_assembly = try assembly.toOwnedSlice(gpa),
        });
    }
    return backends.toOwnedSlice(gpa);
}

fn collectDependencies(gpa: Allocator, io: Io, root: []const u8) ![]const Dependency {
    var dependencies: std.ArrayList(Dependency) = .empty;
    const dependency_files = [_][]const u8{
        ".depend",
        "stdlib/.depend",
        "otherlibs/str/.depend",
        "otherlibs/systhreads/.depend",
        "otherlibs/unix/.depend",
        "otherlibs/runtime_events/.depend",
    };
    for (dependency_files) |path| {
        const content = try readSource(gpa, io, root, path);
        try parseDependencyRules(gpa, content, path, &dependencies);
    }

    // Upstream stdlib/Makefile: implicit dependencies not tracked by ocamlc -depend.
    const stdlib_modules = try collectStdlibModules(gpa, io, root);
    var lazy_interface_available = false;

    for (stdlib_modules) |module| {
        const bootstrap_module = std.mem.eql(u8, module.output, "stdlib") or
            std.mem.eql(u8, module.output, "camlinternalFormatBasics");

        for ([_][]const u8{ ".cmi", ".cmo" }) |ext| {
            const output = try std.fmt.allocPrint(gpa, "stdlib/{s}{s}", .{ module.output, ext });
            var implicit: std.ArrayList([]const u8) = .empty;

            if (!bootstrap_module) {
                try implicit.append(gpa, "stdlib/stdlib.cmi");
            }

            // The bootstrap compiler loads these predefined interfaces when
            // resolving OCaml builtins, even when .depend omits their names.
            if (!bootstrap_module) {
                try implicit.append(gpa, "stdlib/camlinternalFormatBasics.cmi");
            }
            if (lazy_interface_available) {
                try implicit.append(gpa, "stdlib/camlinternalLazy.cmi");
            }

            if (implicit.items.len != 0) {
                try dependencies.append(gpa, .{
                    .output = output,
                    .prerequisites = try implicit.toOwnedSlice(gpa),
                });
            }
        }

        // StdlibModules is dependency-ordered; requiring the Lazy interface
        // only after its declaration avoids introducing a bootstrap cycle.
        if (std.mem.eql(u8, module.output, "camlinternalLazy")) {
            lazy_interface_available = true;
        }
    }

    return dependencies.toOwnedSlice(gpa);
}

fn collectStdlibModules(gpa: Allocator, io: Io, root: []const u8) ![]const Manifest.StdlibModule {
    const text = try readSource(gpa, io, root, "stdlib/StdlibModules");
    const vars = try parseMakeVariables(gpa, text);
    const basenames = vars.get("STDLIB_MODULE_BASENAMES") orelse return error.MissingStdlibModules;

    var modules: std.ArrayList(Manifest.StdlibModule) = .empty;
    var it = std.mem.tokenizeAny(u8, basenames, " \t\r\n");
    while (it.next()) |name| {
        const ml = try std.fmt.allocPrint(gpa, "stdlib/{s}.ml", .{name});
        const mli = try std.fmt.allocPrint(gpa, "stdlib/{s}.mli", .{name});

        const template = try std.fmt.allocPrint(gpa, "{s}.in", .{ml});
        const has_interface = try existsSource(gpa, io, root, mli);
        const has_implementation = try existsSource(gpa, io, root, ml) or
            try existsSource(gpa, io, root, template);
        if (!has_interface or !has_implementation) {
            return error.MissingStdlibSource;
        }

        const plain = std.mem.eql(u8, name, "stdlib") or std.mem.startsWith(u8, name, "camlinternal");
        const output = if (plain)
            try gpa.dupe(u8, name)
        else
            try std.fmt.allocPrint(gpa, "stdlib__{c}{s}", .{
                std.ascii.toUpper(name[0]), name[1..],
            });
        const labels = std.mem.endsWith(u8, name, "Labels");

        try modules.append(gpa, .{
            .output = output,
            .source = ml,
            .interface = mli,
            .archive_member = true,
            .interface_flags = stdlibInterfaceFlags(name),
            .implementation_flags = stdlibImplementationFlags(name),
            .expand_interface_aliases = std.mem.eql(u8, name, "stdlib") or labels,
            .expand_implementation_aliases = std.mem.eql(u8, name, "stdlib"),
        });
    }

    const has_exit_source = try existsSource(gpa, io, root, "stdlib/std_exit.ml");
    const has_exit_interface = try existsSource(gpa, io, root, "stdlib/std_exit.mli");
    if (!has_exit_source or !has_exit_interface) {
        return error.MissingStdlibSource;
    }

    try modules.append(gpa, .{
        .output = "std_exit",
        .source = "stdlib/std_exit.ml",
        .interface = "stdlib/std_exit.mli",
        .archive_member = false,
    });
    return modules.toOwnedSlice(gpa);
}

fn stdlibInterfaceFlags(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "stdlib")) {
        return &.{ "-nopervasives", "-no-alias-deps", "-w", "-49" };
    }
    if (std.mem.eql(u8, name, "camlinternalFormatBasics")) {
        return &.{"-nopervasives"};
    }
    if (std.mem.eql(u8, name, "oo")) {
        return &.{"-no-principal"};
    }
    if (std.mem.eql(u8, name, "buffer")) {
        return &.{ "-w", "+A" };
    }
    if (hasFormatWarnings(name)) {
        return &.{ "-w", "+A", "-w", "-fragile-match" };
    }
    return &.{};
}

fn stdlibImplementationFlags(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "stdlib")) {
        return &.{ "-nopervasives", "-no-alias-deps", "-w", "-49" };
    }
    if (std.mem.eql(u8, name, "camlinternalFormatBasics")) {
        return &.{"-nopervasives"};
    }
    if (std.mem.endsWith(u8, name, "Labels") or std.mem.eql(u8, name, "float")) {
        return &.{ "-nolabels", "-no-alias-deps" };
    }
    if (std.mem.eql(u8, name, "buffer")) {
        return &.{ "-w", "+A" };
    }
    if (hasFormatWarnings(name)) {
        return &.{ "-w", "+A", "-w", "-fragile-match" };
    }
    return &.{};
}

fn hasFormatWarnings(name: []const u8) bool {
    return std.mem.eql(u8, name, "camlinternalFormat") or
        std.mem.eql(u8, name, "printf") or
        std.mem.eql(u8, name, "format") or
        std.mem.eql(u8, name, "scanf");
}

fn collectGeneratedFiles(gpa: Allocator, io: Io, root: []const u8, sources: []const SourceGroup, backends: []const BackendSources) ![]const GeneratedFile {
    var generated: std.ArrayList(GeneratedFile) = .empty;
    try generated.appendSlice(gpa, &[_]GeneratedFile{
        .{
            .output = "utils/config.common.ml",
            .inputs = &.{"utils/config.common.ml.in"},
            .transform = "configure",
        },
        .{
            .output = "utils/config.generated.ml",
            .inputs = &.{"utils/config.generated.ml.in"},
            .transform = "configure",
        },
        .{
            .output = "utils/config_boot.ml",
            .inputs = &.{ "utils/config.fixed.ml", "utils/config.common.ml" },
            .transform = "concat",
        },
        .{
            .output = "utils/config_main.ml",
            .inputs = &.{ "utils/config.generated.ml", "utils/config.common.ml" },
            .transform = "concat",
        },
        .{
            .output = "utils/config.ml",
            .inputs = &.{"utils/config_main.ml"},
            .transform = "copy",
        },
        .{
            .output = "utils/config_boot.mli",
            .inputs = &.{"utils/config.mli"},
            .transform = "copy",
        },
        .{
            .output = "utils/config_main.mli",
            .inputs = &.{"utils/config.mli"},
            .transform = "copy",
        },
        .{
            .output = "utils/domainstate.ml",
            .inputs = &.{ "utils/domainstate.ml.c", "runtime/caml/domain_state.tbl" },
            .transform = "c_preprocess",
        },
        .{
            .output = "utils/domainstate.mli",
            .inputs = &.{ "utils/domainstate.mli.c", "runtime/caml/domain_state.tbl" },
            .transform = "c_preprocess",
        },
        .{
            .output = "stdlib/sys.ml",
            .inputs = &.{"stdlib/sys.ml.in"},
            .transform = "configure",
        },
        .{
            .output = "runtime/caml/m.h",
            .inputs = &.{"runtime/caml/m.h.in"},
            .transform = "configure",
        },
        .{
            .output = "runtime/caml/s.h",
            .inputs = &.{"runtime/caml/s.h.in"},
            .transform = "configure",
        },
        .{
            .output = "runtime/caml/exec.h",
            .inputs = &.{"runtime/caml/exec.h.in"},
            .transform = "configure",
        },
        .{
            .output = "runtime/caml/version.h",
            .inputs = &.{"runtime/caml/version.h.in"},
            .transform = "configure",
        },
        .{
            .output = "runtime/caml/opnames.h",
            .inputs = &.{"runtime/caml/instruct.h"},
            .transform = "opnames",
        },
        .{
            .output = "runtime/caml/jumptbl.h",
            .inputs = &.{"runtime/caml/instruct.h"},
            .transform = "jumptbl",
        },
        .{
            .output = "runtime/build_config.h",
            .inputs = &.{"runtime/caml/config.h"},
            .transform = "build_config",
        },
        .{
            .output = "lambda/runtimedef.ml",
            .inputs = &.{ "runtime/caml/fail.h", "runtime/primitives" },
            .transform = "runtimedef",
        },
        .{
            .output = "parsing/camlinternalMenhirLib.ml",
            .inputs = &.{"boot/menhir/menhirLib.ml"},
            .transform = "copy",
        },
        .{
            .output = "parsing/camlinternalMenhirLib.mli",
            .inputs = &.{"boot/menhir/menhirLib.mli"},
            .transform = "menhir_mli",
        },
        .{
            .output = "parsing/parser.ml",
            .inputs = &.{"boot/menhir/parser.ml"},
            .transform = "menhir_rename",
        },
        .{
            .output = "parsing/parser.mli",
            .inputs = &.{"boot/menhir/parser.mli"},
            .transform = "menhir_rename",
        },
        .{
            .output = "otherlibs/dynlink/dynlink_config.ml",
            .inputs = &.{"otherlibs/dynlink/dynlink_config.ml.in"},
            .transform = "configure",
        },
        .{
            .output = "otherlibs/dynlink/dynlink_platform_intf.mli",
            .inputs = &.{"otherlibs/dynlink/dynlink_platform_intf.ml"},
            .transform = "ocamlc_interface",
        },
        .{
            .output = "otherlibs/dynlink/byte/dynlink.mli",
            .inputs = &.{"otherlibs/dynlink/dynlink.mli"},
            .transform = "copy",
        },
        .{
            .output = "otherlibs/dynlink/native/dynlink.mli",
            .inputs = &.{"otherlibs/dynlink/dynlink.mli"},
            .transform = "copy",
        },
        .{
            .output = "tools/opnames.ml",
            .inputs = &.{ "runtime/caml/instruct.h", "tools/make_opcodes.mll" },
            .transform = "make_opcodes",
        },
        .{
            .output = "bytecomp/opcodes.ml",
            .inputs = &.{"runtime/caml/instruct.h"},
            .transform = "bootstrap_opcodes",
        },
        .{
            .output = "bytecomp/opcodes.mli",
            .inputs = &.{"runtime/caml/instruct.h"},
            .transform = "bootstrap_opcodes_interface",
        },
    });
    for ([_][]const u8{
        "compilerlibs",             "stdlib",               "otherlibs/str",  "otherlibs/dynlink",
        "otherlibs/runtime_events", "otherlibs/systhreads", "otherlibs/unix", "ocamldoc",
    }) |dir| {
        const template = try std.fmt.allocPrint(gpa, "{s}/META.in", .{dir});
        const inputs = try gpa.dupe([]const u8, &.{template});
        try generated.append(gpa, .{
            .output = try std.fmt.allocPrint(gpa, "{s}/META", .{dir}),
            .inputs = inputs,
            .transform = "configure",
        });
    }
    for ([_][]const u8{ "unix", "win32" }) |platform| {
        const source = try std.fmt.allocPrint(gpa, "otherlibs/unix/unix_{s}.ml", .{platform});
        const inputs = try gpa.dupe([]const u8, &.{source});
        try generated.append(gpa, .{
            .output = "otherlibs/unix/unix.ml",
            .inputs = inputs,
            .transform = "copy",
            .platform = platform,
        });
    }
    for ([_][]const u8{ "byte", "native" }) |mode| {
        for ([_][]const u8{ "topeval", "trace", "topmain" }) |module| {
            const interface = try std.fmt.allocPrint(gpa, "toplevel/{s}.mli", .{module});
            const inputs = try gpa.dupe([]const u8, &.{interface});
            try generated.append(gpa, .{
                .output = try std.fmt.allocPrint(gpa, "toplevel/{s}/{s}.mli", .{ mode, module }),
                .inputs = inputs,
                .transform = "copy",
            });
        }
    }
    const runtime_common = sourceGroupFiles(sources, "runtime_common");
    const runtime_bytecode = sourceGroupFiles(sources, "runtime_bytecode_only");
    const all_bytecode_c = try gpa.alloc([]const u8, runtime_common.len + runtime_bytecode.len);
    @memcpy(all_bytecode_c[0..runtime_common.len], runtime_common);
    @memcpy(all_bytecode_c[runtime_common.len..], runtime_bytecode);
    const runtime_platform_inputs = &[_]Manifest.PlatformInputs{
        .{ .platform = "unix", .files = &.{"runtime/unix.c"} },
        .{ .platform = "win32", .files = &.{"runtime/win32.c"} },
    };
    try generated.append(gpa, .{
        .output = "runtime/primitives",
        .inputs = all_bytecode_c,
        .platform_inputs = runtime_platform_inputs,
        .transform = "primitive_names",
    });
    const primsc_inputs = try gpa.alloc([]const u8, all_bytecode_c.len + 1);
    primsc_inputs[0] = "runtime/primitives";
    @memcpy(primsc_inputs[1..], all_bytecode_c);
    try generated.append(gpa, .{
        .output = "runtime/prims.c",
        .inputs = primsc_inputs,
        .platform_inputs = runtime_platform_inputs,
        .transform = "primitive_table",
    });
    for (backends) |backend| {
        for (backend.files) |path| {
            const base = std.fs.path.basename(path);
            if (std.mem.eql(u8, base, "emit.mlp")) {
                const inputs = try gpa.dupe([]const u8, &.{ path, "tools/cvt_emit.mll" });
                try generated.append(gpa, .{
                    .output = "asmcomp/emit.ml",
                    .inputs = inputs,
                    .transform = "cvt_emit",
                    .arch = backend.arch,
                });
            } else {
                try generated.append(gpa, .{
                    .output = try std.fmt.allocPrint(gpa, "asmcomp/{s}", .{base}),
                    .inputs = try gpa.dupe([]const u8, &.{path}),
                    .transform = "copy",
                    .arch = backend.arch,
                });
            }
        }
    }
    var generated_outputs = std.StringHashMap(void).init(gpa);
    for (generated.items) |rule| try generated_outputs.put(rule.output, {});
    for (sources) |group| {
        for (group.files) |path| {
            if (std.mem.endsWith(u8, path, ".mll")) {
                const output = try std.fmt.allocPrint(gpa, "{s}.ml", .{path[0 .. path.len - 4]});
                if (!generated_outputs.contains(output)) {
                    try generated_outputs.put(output, {});
                    try generated.append(gpa, .{
                        .output = output,
                        .inputs = try gpa.dupe([]const u8, &.{path}),
                        .transform = "ocamllex",
                    });
                }
            } else if (std.mem.endsWith(u8, path, ".mly") and !std.mem.eql(u8, path, "parsing/parser.mly")) {
                const stem = path[0 .. path.len - 4];
                for ([_][]const u8{ ".ml", ".mli" }) |suffix| {
                    const output = try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, suffix });
                    if (!generated_outputs.contains(output)) {
                        try generated_outputs.put(output, {});
                        try generated.append(gpa, .{
                            .output = output,
                            .inputs = try gpa.dupe([]const u8, &.{path}),
                            .transform = "ocamlyacc",
                        });
                    }
                }
            }
        }
    }
    // Source files must exist or have a generation rule.
    for (sources) |group| {
        for (group.files) |path| {
            if (std.mem.endsWith(u8, path, ".mll") or std.mem.endsWith(u8, path, ".mly")) continue;
            if (!generated_outputs.contains(path) and !try existsSource(gpa, io, root, path)) {
                std.log.err("source group {s} references missing file {s}", .{ group.name, path });
                return error.MissingSource;
            }
        }
    }

    return generated.toOwnedSlice(gpa);
}

fn writeManifest(io: Io, path: []const u8, manifest: Manifest) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
    }

    const output_file = try Io.Dir.cwd().createFile(io, path, .{});
    defer output_file.close(io);
    var output_file_buffer: [1024 * 1024]u8 = undefined;
    var output_writer = output_file.writer(io, &output_file_buffer);
    const output = &output_writer.interface;

    try output.writeAll("// Generated by zig build prepare.\n");
    try std.zon.stringify.serialize(manifest, .{}, output);
    try output.writeAll("\n");
    try output_writer.flush();
}

fn parseMakeVariables(gpa: Allocator, text: []const u8) !std.StringHashMap([]const u8) {
    var vars = std.StringHashMap([]const u8).init(gpa);
    var line_buffer: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (try nextMakeLine(gpa, &lines, &line_buffer)) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len > 0 and validVariable(key) and !vars.contains(key)) {
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            try vars.put(try gpa.dupe(u8, key), try gpa.dupe(u8, value));
        }
    }
    return vars;
}

/// Joins backslash-continued lines. The result borrows buffer until the next call.
fn nextMakeLine(gpa: Allocator, lines: *std.mem.SplitIterator(u8, .scalar), buffer: *std.ArrayList(u8)) !?[]const u8 {
    buffer.clearRetainingCapacity();
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        const continued = std.mem.endsWith(u8, trimmed, "\\");
        const fragment = if (continued) trimmed[0 .. trimmed.len - 1] else trimmed;
        try buffer.appendSlice(gpa, fragment);
        try buffer.append(gpa, ' ');
        if (!continued) return std.mem.trim(u8, buffer.items, " \t\r\n");
    }
    return null;
}

fn validVariable(key: []const u8) bool {
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn expandMakeExpression(gpa: Allocator, vars: *const std.StringHashMap([]const u8), expression: []const u8, depth: usize) ![]const u8 {
    if (depth > 32) return error.RecursiveMakeVariable;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < expression.len) {
        if (!std.mem.startsWith(u8, expression[i..], "$(")) {
            try result.append(gpa, expression[i]);
            i += 1;
            continue;
        }
        const start = i + 2;
        var level: usize = 1;
        i = start;
        while (i < expression.len and level != 0) : (i += 1) {
            if (std.mem.startsWith(u8, expression[i..], "$(")) {
                level += 1;
                i += 1;
            } else if (expression[i] == ')') {
                level -= 1;
            }
        }
        if (level != 0) return error.InvalidMakeExpression;
        const inner = std.mem.trim(u8, expression[start .. i - 1], " \t");
        if (std.mem.startsWith(u8, inner, "addprefix ")) {
            const args = inner["addprefix ".len..];
            var comma: ?usize = null;
            var nested: usize = 0;
            for (args, 0..) |c, n| {
                if (std.mem.startsWith(u8, args[n..], "$(")) nested += 1;
                if (c == ')' and nested > 0) nested -= 1;
                if (c == ',' and nested == 0) {
                    comma = n;
                    break;
                }
            }
            const split = comma orelse return error.InvalidMakeExpression;
            const prefix = std.mem.trim(u8, args[0..split], " \t");
            const words = try expandMakeExpression(gpa, vars, args[split + 1 ..], depth + 1);
            var tokens = std.mem.tokenizeAny(u8, words, " \t\r\n");
            while (tokens.next()) |word| {
                try result.appendSlice(gpa, prefix);
                try result.appendSlice(gpa, word);
                try result.append(gpa, ' ');
            }
        } else {
            const value = vars.get(inner) orelse {
                std.log.err("unsupported Make expression $({s})", .{inner});
                return error.UnsupportedMakeExpression;
            };
            const expanded = try expandMakeExpression(gpa, vars, value, depth + 1);
            try result.appendSlice(gpa, expanded);
        }
    }
    return result.toOwnedSlice(gpa);
}

fn parseDependencyRules(gpa: Allocator, text: []const u8, name: []const u8, rules: *std.ArrayList(Dependency)) !void {
    const prefix = std.fs.path.dirname(name) orelse ".";
    var arch: ?[]const u8 = null;
    var line_buffer: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (try nextMakeLine(gpa, &lines, &line_buffer)) |line| {
        if (std.mem.startsWith(u8, line, "ifeq \"$(ARCH)\" \"")) {
            const start = "ifeq \"$(ARCH)\" \"".len;
            const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return error.InvalidDependencyCondition;
            if (arch != null) return error.NestedDependencyCondition;
            arch = try gpa.dupe(u8, line[start..end]);
        } else if (std.mem.startsWith(u8, line, "endif")) {
            if (arch == null) return error.InvalidDependencyCondition;
            arch = null;
        } else if (line.len != 0 and line[0] != '#') {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidDependencyRule;
            const target = std.mem.trim(u8, line[0..colon], " \t");
            const output = try prefixed(gpa, prefix, target);
            var deps: std.ArrayList([]const u8) = .empty;
            var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t\r\n");
            while (words.next()) |word| {
                const prerequisite = try prefixed(gpa, prefix, word);
                try deps.append(gpa, prerequisite);
            }
            try rules.append(gpa, .{
                .output = output,
                .prerequisites = try deps.toOwnedSlice(gpa),
                .arch = arch,
            });
        }
    }
    if (arch != null) return error.UnclosedDependencyCondition;
}

fn prefixed(gpa: Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, prefix, ".")) return gpa.dupe(u8, path);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, path });
}

fn sourceGroupFiles(groups: []const SourceGroup, name: []const u8) []const []const u8 {
    for (groups) |group| if (std.mem.eql(u8, group.name, name)) return group.files;
    unreachable;
}

fn readSource(gpa: Allocator, io: Io, root: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(gpa, &.{ root, name });
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

fn existsSource(gpa: Allocator, io: Io, root: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(gpa, &.{ root, name });
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "expand only the supported OCaml source-list syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var vars = std.StringHashMap([]const u8).init(gpa);
    try vars.put("items", "one.ml two.mli");
    const actual = try expandMakeExpression(gpa, &vars, "$(addprefix dir/, $(items)) $(addprefix other/, three.ml)", 0);
    try std.testing.expectEqualStrings("dir/one.ml dir/two.mli  other/three.ml ", actual);
    try std.testing.expectError(error.InvalidMakeExpression, expandMakeExpression(gpa, &vars, "$(addprefix a/, $(items)", 0));
}

test "dependency rules retain backend and subdirectory context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var rules: std.ArrayList(Dependency) = .empty;
    try parseDependencyRules(gpa, "a.cmx : \\\n  b.cmx \\\n  c.cmi\nifeq \"$(ARCH)\" \"arm64\"\narch.cmx : a.cmx\nendif\n", "stdlib/.depend", &rules);
    try std.testing.expectEqual(@as(usize, 2), rules.items.len);
    try std.testing.expectEqualStrings("stdlib/a.cmx", rules.items[0].output);
    try std.testing.expectEqualStrings("stdlib/c.cmi", rules.items[0].prerequisites[1]);
    try std.testing.expectEqualStrings("arm64", rules.items[1].arch.?);
}

test "Make variables retain continued values across lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const text =
        \\files = one.ml \
        \\  two.ml
        \\empty =
        \\last = three.ml
    ;
    const vars = try parseMakeVariables(gpa, text);
    try std.testing.expectEqualStrings("one.ml    two.ml", vars.get("files").?);
    try std.testing.expectEqualStrings("", vars.get("empty").?);
    try std.testing.expectEqualStrings("three.ml", vars.get("last").?);
}

test "generated emit rules keep each backend's input array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const sources = [_]SourceGroup{
        .{ .name = "runtime_common", .files = &.{} },
        .{ .name = "runtime_bytecode_only", .files = &.{} },
    };
    const backends = [_]BackendSources{
        .{ .arch = "amd64", .files = &.{"asmcomp/amd64/emit.mlp"}, .runtime_assembly = &.{} },
        .{ .arch = "arm64", .files = &.{"asmcomp/arm64/emit.mlp"}, .runtime_assembly = &.{} },
    };
    const generated = try collectGeneratedFiles(gpa, std.testing.io, ".", &sources, &backends);
    var emit_count: usize = 0;
    for (generated) |rule| {
        if (!std.mem.eql(u8, rule.transform, "cvt_emit")) continue;
        const backend = backends[emit_count];
        try std.testing.expectEqualStrings(backend.arch, rule.arch.?);
        try std.testing.expectEqualStrings(backend.files[0], rule.inputs[0]);
        try std.testing.expectEqualStrings("tools/cvt_emit.mll", rule.inputs[1]);
        emit_count += 1;
    }
    try std.testing.expectEqual(backends.len, emit_count);
}

test "compiler archive membership follows upstream source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const groups = [_]SourceGroup{
        .{ .name = "ocamlcommon", .files = &.{ "a/first.mli", "a/first.ml", "a/second.ml", "a/only.mli" } },
        .{ .name = "ocamlbytecomp", .files = &.{"b/third.ml"} },
        .{ .name = "ocamlc", .files = &.{"driver/main.ml"} },
        .{ .name = "ocamlmiddleend", .files = &.{} },
    };
    const modules = try collectCompilerModules(allocator, &groups, &.{});
    const stdlib = [_]Manifest.StdlibModule{
        .{
            .output = "stdlib",
            .source = "stdlib/stdlib.ml",
            .interface = "stdlib/stdlib.mli",
            .archive_member = true,
        },
        .{
            .output = "std_exit",
            .source = "stdlib/std_exit.ml",
            .interface = "stdlib/std_exit.mli",
            .archive_member = false,
        },
    };
    const archives = try collectArchives(allocator, &stdlib, modules);

    try std.testing.expectEqual(@as(usize, 5), modules.len);
    try std.testing.expectEqualStrings("a/first", modules[0].stem);
    try std.testing.expect(modules[0].interface != null);
    try std.testing.expect(modules[2].implementation == null);
    try std.testing.expectEqualStrings("stdlib/stdlib", archives[0].members[0]);
    try std.testing.expectEqual(@as(usize, 2), archives[1].members.len);
    try std.testing.expectEqualStrings("a/first", archives[1].members[0]);
    try std.testing.expectEqualStrings("a/second", archives[1].members[1]);
    try std.testing.expectEqualStrings("b/third", archives[2].members[0]);
}
