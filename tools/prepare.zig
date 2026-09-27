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
    const version_file = try readSource(gpa, io, root, "VERSION");
    const version = std.mem.trim(u8, std.mem.sliceTo(version_file, '\n'), " \t\r");

    const root_make = try readSource(gpa, io, root, "Makefile");
    const make_vars = try parseVariables(gpa, root_make);
    const stdlib_make = try readSource(gpa, io, root, "stdlib/StdlibModules");
    const stdlib_vars = try parseVariables(gpa, stdlib_make);

    var sources: std.ArrayList(SourceGroup) = .empty;
    const source_vars = [_]struct { name: []const u8, variable: []const u8, c_prefix: ?[]const u8 = null }{
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
        const expanded = try expand(gpa, &make_vars, expression, 0);
        var files: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, expanded, " \t\r\n");
        while (tokens.next()) |token| {
            const path = if (entry.c_prefix) |prefix|
                try std.fmt.allocPrint(gpa, "{s}{s}.c", .{ prefix, token })
            else
                token;
            try files.append(gpa, path);
        }
        if (files.items.len == 0) return error.EmptySourceGroup;
        try sources.append(gpa, .{ .name = entry.name, .files = try files.toOwnedSlice(gpa) });
    }
    try sources.append(gpa, .{ .name = "runtime_platform_unix", .files = &.{"runtime/unix.c"} });
    try sources.append(gpa, .{ .name = "runtime_platform_win32", .files = &.{"runtime/win32.c"} });
    try sources.append(gpa, .{ .name = "ocamlyacc_win32", .files = &.{"yacc/wstr.c"} });

    const modules = stdlib_vars.get("STDLIB_MODULE_BASENAMES") orelse return error.MissingStdlibModules;
    var stdlib_files: std.ArrayList([]const u8) = .empty;
    var module_it = std.mem.tokenizeAny(u8, modules, " \t\r\n");
    while (module_it.next()) |name| {
        const ml = try std.fmt.allocPrint(gpa, "stdlib/{s}.ml", .{name});
        const mli = try std.fmt.allocPrint(gpa, "stdlib/{s}.mli", .{name});
        if (try existsSource(gpa, io, root, mli)) try stdlib_files.append(gpa, mli);
        if (try existsSource(gpa, io, root, ml) or try existsSource(gpa, io, root, try std.fmt.allocPrint(gpa, "{s}.in", .{ml}))) {
            try stdlib_files.append(gpa, ml);
        } else return error.MissingStdlibSource;
    }
    try sources.append(gpa, .{ .name = "stdlib", .files = try stdlib_files.toOwnedSlice(gpa) });

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
            if (!try existsSource(gpa, io, root, path)) return error.MissingBackendSource;
            try paths.append(gpa, path);
        }
        var assembly: std.ArrayList([]const u8) = .empty;
        const asm_path = try std.fmt.allocPrint(gpa, "runtime/{s}.S", .{arch});
        if (try existsSource(gpa, io, root, asm_path)) try assembly.append(gpa, asm_path);
        if (std.mem.eql(u8, arch, "amd64")) {
            if (!try existsSource(gpa, io, root, "runtime/amd64nt.asm")) return error.MissingBackendSource;
            try assembly.append(gpa, "runtime/amd64nt.asm");
        }
        try backends.append(gpa, .{ .arch = arch, .files = try paths.toOwnedSlice(gpa), .runtime_assembly = try assembly.toOwnedSlice(gpa) });
    }

    var dependencies: std.ArrayList(Dependency) = .empty;
    const dependency_files = [_][]const u8{
        ".depend",                      "stdlib/.depend",         "otherlibs/str/.depend",
        "otherlibs/systhreads/.depend", "otherlibs/unix/.depend", "otherlibs/runtime_events/.depend",
    };
    for (dependency_files) |path| {
        const content = try readSource(gpa, io, root, path);
        try parseDepend(gpa, content, path, &dependencies);
    }

    var generated: std.ArrayList(GeneratedFile) = .empty;
    try generated.appendSlice(gpa, &[_]GeneratedFile{
        .{ .output = "utils/config.common.ml", .inputs = &.{"utils/config.common.ml.in"}, .transform = "configure" },
        .{ .output = "utils/config.generated.ml", .inputs = &.{"utils/config.generated.ml.in"}, .transform = "configure" },
        .{ .output = "utils/config_boot.ml", .inputs = &.{ "utils/config.fixed.ml", "utils/config.common.ml" }, .transform = "concat" },
        .{ .output = "utils/config_main.ml", .inputs = &.{ "utils/config.generated.ml", "utils/config.common.ml" }, .transform = "concat" },
        .{ .output = "utils/config.ml", .inputs = &.{"utils/config_main.ml"}, .transform = "copy" },
        .{ .output = "utils/config_boot.mli", .inputs = &.{"utils/config.mli"}, .transform = "copy" },
        .{ .output = "utils/config_main.mli", .inputs = &.{"utils/config.mli"}, .transform = "copy" },
        .{ .output = "utils/domainstate.ml", .inputs = &.{ "utils/domainstate.ml.c", "runtime/caml/domain_state.tbl" }, .transform = "c_preprocess" },
        .{ .output = "utils/domainstate.mli", .inputs = &.{ "utils/domainstate.mli.c", "runtime/caml/domain_state.tbl" }, .transform = "c_preprocess" },
        .{ .output = "stdlib/sys.ml", .inputs = &.{"stdlib/sys.ml.in"}, .transform = "configure" },
        .{ .output = "runtime/caml/m.h", .inputs = &.{"runtime/caml/m.h.in"}, .transform = "configure" },
        .{ .output = "runtime/caml/s.h", .inputs = &.{"runtime/caml/s.h.in"}, .transform = "configure" },
        .{ .output = "runtime/caml/exec.h", .inputs = &.{"runtime/caml/exec.h.in"}, .transform = "configure" },
        .{ .output = "runtime/caml/version.h", .inputs = &.{"runtime/caml/version.h.in"}, .transform = "configure" },
        .{ .output = "runtime/caml/opnames.h", .inputs = &.{"runtime/caml/instruct.h"}, .transform = "opnames" },
        .{ .output = "runtime/caml/jumptbl.h", .inputs = &.{"runtime/caml/instruct.h"}, .transform = "jumptbl" },
        .{ .output = "runtime/build_config.h", .inputs = &.{"runtime/caml/config.h"}, .transform = "build_config" },
        .{ .output = "lambda/runtimedef.ml", .inputs = &.{ "runtime/caml/fail.h", "runtime/primitives" }, .transform = "runtimedef" },
        .{ .output = "parsing/camlinternalMenhirLib.ml", .inputs = &.{"boot/menhir/menhirLib.ml"}, .transform = "copy" },
        .{ .output = "parsing/camlinternalMenhirLib.mli", .inputs = &.{"boot/menhir/menhirLib.mli"}, .transform = "menhir_mli" },
        .{ .output = "parsing/parser.ml", .inputs = &.{"boot/menhir/parser.ml"}, .transform = "menhir_rename" },
        .{ .output = "parsing/parser.mli", .inputs = &.{"boot/menhir/parser.mli"}, .transform = "menhir_rename" },
        .{ .output = "otherlibs/dynlink/dynlink_config.ml", .inputs = &.{"otherlibs/dynlink/dynlink_config.ml.in"}, .transform = "configure" },
        .{ .output = "otherlibs/dynlink/dynlink_platform_intf.mli", .inputs = &.{"otherlibs/dynlink/dynlink_platform_intf.ml"}, .transform = "ocamlc_interface" },
        .{ .output = "otherlibs/dynlink/byte/dynlink.mli", .inputs = &.{"otherlibs/dynlink/dynlink.mli"}, .transform = "copy" },
        .{ .output = "otherlibs/dynlink/native/dynlink.mli", .inputs = &.{"otherlibs/dynlink/dynlink.mli"}, .transform = "copy" },
        .{ .output = "tools/opnames.ml", .inputs = &.{ "runtime/caml/instruct.h", "tools/make_opcodes.mll" }, .transform = "make_opcodes" },
        .{ .output = "bytecomp/opcodes.ml", .inputs = &.{ "runtime/caml/instruct.h", "tools/make_opcodes.mll" }, .transform = "make_opcodes" },
        .{ .output = "bytecomp/opcodes.mli", .inputs = &.{"bytecomp/opcodes.ml"}, .transform = "ocamlc_interface" },
    });
    for ([_][]const u8{
        "compilerlibs",             "stdlib",               "otherlibs/str",  "otherlibs/dynlink",
        "otherlibs/runtime_events", "otherlibs/systhreads", "otherlibs/unix", "ocamldoc",
    }) |dir| {
        try generated.append(gpa, .{
            .output = try std.fmt.allocPrint(gpa, "{s}/META", .{dir}),
            .inputs = try gpa.dupe([]const u8, &.{try std.fmt.allocPrint(gpa, "{s}/META.in", .{dir})}),
            .transform = "configure",
        });
    }
    for ([_][]const u8{ "unix", "win32" }) |platform| {
        try generated.append(gpa, .{
            .output = "otherlibs/unix/unix.ml",
            .inputs = try gpa.dupe([]const u8, &.{try std.fmt.allocPrint(gpa, "otherlibs/unix/unix_{s}.ml", .{platform})}),
            .transform = "copy",
            .platform = platform,
        });
    }
    for ([_][]const u8{ "byte", "native" }) |mode| {
        for ([_][]const u8{ "topeval", "trace", "topmain" }) |module| {
            try generated.append(gpa, .{
                .output = try std.fmt.allocPrint(gpa, "toplevel/{s}/{s}.mli", .{ mode, module }),
                .inputs = try gpa.dupe([]const u8, &.{try std.fmt.allocPrint(gpa, "toplevel/{s}.mli", .{module})}),
                .transform = "copy",
            });
        }
    }
    const runtime_common = sourceGroup(sources.items, "runtime_common");
    const runtime_bytecode = sourceGroup(sources.items, "runtime_bytecode_only");
    const all_bytecode_c = try gpa.alloc([]const u8, runtime_common.len + runtime_bytecode.len);
    @memcpy(all_bytecode_c[0..runtime_common.len], runtime_common);
    @memcpy(all_bytecode_c[runtime_common.len..], runtime_bytecode);
    const runtime_platform_inputs = &[_]@import("manifest.zig").PlatformInputs{
        .{ .platform = "unix", .files = &.{"runtime/unix.c"} },
        .{ .platform = "win32", .files = &.{"runtime/win32.c"} },
    };
    try generated.append(gpa, .{ .output = "runtime/primitives", .inputs = all_bytecode_c, .platform_inputs = runtime_platform_inputs, .transform = "primitive_names" });
    const primsc_inputs = try gpa.alloc([]const u8, all_bytecode_c.len + 1);
    primsc_inputs[0] = "runtime/primitives";
    @memcpy(primsc_inputs[1..], all_bytecode_c);
    try generated.append(gpa, .{ .output = "runtime/prims.c", .inputs = primsc_inputs, .platform_inputs = runtime_platform_inputs, .transform = "primitive_table" });
    for (backends.items) |backend| {
        for (backend.files) |path| {
            const base = std.fs.path.basename(path);
            if (std.mem.eql(u8, base, "emit.mlp")) {
                try generated.append(gpa, .{ .output = "asmcomp/emit.ml", .inputs = &.{ path, "tools/cvt_emit.mll" }, .transform = "cvt_emit", .arch = backend.arch });
            } else {
                try generated.append(gpa, .{ .output = try std.fmt.allocPrint(gpa, "asmcomp/{s}", .{base}), .inputs = try gpa.dupe([]const u8, &.{path}), .transform = "copy", .arch = backend.arch });
            }
        }
    }
    var seen = std.StringHashMap(void).init(gpa);
    for (generated.items) |rule| try seen.put(rule.output, {});
    for (sources.items) |group| {
        for (group.files) |path| {
            if (std.mem.endsWith(u8, path, ".mll")) {
                const output = try std.fmt.allocPrint(gpa, "{s}.ml", .{path[0 .. path.len - 4]});
                if (!seen.contains(output)) {
                    try seen.put(output, {});
                    try generated.append(gpa, .{ .output = output, .inputs = try gpa.dupe([]const u8, &.{path}), .transform = "ocamllex" });
                }
            } else if (std.mem.endsWith(u8, path, ".mly") and !std.mem.eql(u8, path, "parsing/parser.mly")) {
                const stem = path[0 .. path.len - 4];
                for ([_][]const u8{ ".ml", ".mli" }) |suffix| {
                    const output = try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, suffix });
                    if (!seen.contains(output)) {
                        try seen.put(output, {});
                        try generated.append(gpa, .{ .output = output, .inputs = try gpa.dupe([]const u8, &.{path}), .transform = "ocamlyacc" });
                    }
                }
            }
        }
    }
    // Make's source lists can mention generated files, but nothing else may be
    // missing. This catches an unsupported upstream source-layout change.
    var generated_outputs = std.StringHashMap(void).init(gpa);
    for (generated.items) |rule| try generated_outputs.put(rule.output, {});
    for (sources.items) |group| {
        for (group.files) |path| {
            if (std.mem.endsWith(u8, path, ".mll") or std.mem.endsWith(u8, path, ".mly")) continue;
            if (!generated_outputs.contains(path) and !try existsSource(gpa, io, root, path)) {
                std.log.err("source group {s} references missing file {s}", .{ group.name, path });
                return error.MissingSource;
            }
        }
    }

    const manifest: Manifest = .{
        .ocaml_version = version,
        .source_hash = argv[2],
        .source_groups = sources.items,
        .backend_sources = backends.items,
        .generated_files = generated.items,
        .dependencies = dependencies.items,
    };

    ensure_dir: {
        const dir = std.fs.path.dirname(argv[3]) orelse break :ensure_dir;
        try Io.Dir.cwd().createDirPath(io, dir);
    }

    const output_file = try Io.Dir.cwd().createFile(io, argv[3], .{});
    defer output_file.close(io);
    var output_file_buffer: [1024 * 1024]u8 = undefined;
    var output_writer = output_file.writer(io, &output_file_buffer);
    const output = &output_writer.interface;

    try output.writeAll("// Generated by zig build prepare.\n");
    try std.zon.stringify.serialize(manifest, .{}, output);
    try output.writeAll("\n");
    try output_writer.flush();

    std.log.info("prepared OCaml {s}: {d} source groups, {d} dependency rules, {d} generated-file rules", .{ version, sources.items.len, dependencies.items.len, generated.items.len });
}

fn parseVariables(a: Allocator, text: []const u8) !std.StringHashMap([]const u8) {
    var vars = std.StringHashMap([]const u8).init(a);
    var current: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trimEnd(u8, line, " \t\r");
        const continuation = std.mem.endsWith(u8, clean, "\\");
        try current.appendSlice(a, if (continuation) clean[0 .. clean.len - 1] else clean);
        try current.append(a, ' ');
        if (continuation) continue;
        const full = std.mem.trim(u8, current.items, " \t\r\n");
        if (std.mem.indexOfScalar(u8, full, '=')) |eq| {
            const key = std.mem.trim(u8, full[0..eq], " \t");
            if (key.len > 0 and validVariable(key)) {
                if (!vars.contains(key)) try vars.put(try a.dupe(u8, key), try a.dupe(u8, std.mem.trim(u8, full[eq + 1 ..], " \t")));
            }
        }
        current.clearRetainingCapacity();
    }
    return vars;
}

fn validVariable(key: []const u8) bool {
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn expand(a: Allocator, vars: *const std.StringHashMap([]const u8), expression: []const u8, depth: usize) ![]const u8 {
    if (depth > 32) return error.RecursiveMakeVariable;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < expression.len) {
        if (!std.mem.startsWith(u8, expression[i..], "$(")) {
            try result.append(a, expression[i]);
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
            const words = try expand(a, vars, args[split + 1 ..], depth + 1);
            var tokens = std.mem.tokenizeAny(u8, words, " \t\r\n");
            while (tokens.next()) |word| {
                try result.appendSlice(a, prefix);
                try result.appendSlice(a, word);
                try result.append(a, ' ');
            }
        } else if (std.mem.eql(u8, inner, "arch_specific_SOURCES") or
            std.mem.eql(u8, inner, "TSAN_NATIVE_RUNTIME_C_SOURCES") or
            std.mem.eql(u8, inner, "UNIX_OR_WIN32"))
        {
            // These are supplied by a target profile, never by prepare.
        } else {
            const value = vars.get(inner) orelse {
                std.log.err("unsupported Make expression $({s})", .{inner});
                return error.UnsupportedMakeExpression;
            };
            try result.appendSlice(a, try expand(a, vars, value, depth + 1));
        }
    }
    return result.toOwnedSlice(a);
}

fn parseDepend(a: Allocator, text: []const u8, name: []const u8, rules: *std.ArrayList(Dependency)) !void {
    const prefix = std.fs.path.dirname(name) orelse ".";
    var arch: ?[]const u8 = null;
    var line_buf: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        const continued = std.mem.endsWith(u8, trimmed, "\\");
        try line_buf.appendSlice(a, if (continued) trimmed[0 .. trimmed.len - 1] else trimmed);
        try line_buf.append(a, ' ');
        if (continued) continue;
        const full = std.mem.trim(u8, line_buf.items, " \t\r\n");
        if (std.mem.startsWith(u8, full, "ifeq \"$(ARCH)\" \"")) {
            const start = "ifeq \"$(ARCH)\" \"".len;
            const end = std.mem.indexOfScalarPos(u8, full, start, '"') orelse return error.InvalidDependencyCondition;
            if (arch != null) return error.NestedDependencyCondition;
            arch = try a.dupe(u8, full[start..end]);
        } else if (std.mem.startsWith(u8, full, "endif")) {
            if (arch == null) return error.InvalidDependencyCondition;
            arch = null;
        } else if (full.len != 0 and full[0] != '#') {
            const colon = std.mem.indexOfScalar(u8, full, ':') orelse return error.InvalidDependencyRule;
            const output = try prefixed(a, prefix, std.mem.trim(u8, full[0..colon], " \t"));
            var deps: std.ArrayList([]const u8) = .empty;
            var words = std.mem.tokenizeAny(u8, full[colon + 1 ..], " \t\r\n");
            while (words.next()) |word| try deps.append(a, try prefixed(a, prefix, word));
            try rules.append(a, .{ .output = output, .prerequisites = try deps.toOwnedSlice(a), .arch = arch });
        }
        line_buf.clearRetainingCapacity();
    }
    if (arch != null) return error.UnclosedDependencyCondition;
}

fn prefixed(a: Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, prefix, ".")) return a.dupe(u8, path);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, path });
}

fn sourceGroup(groups: []const SourceGroup, name: []const u8) []const []const u8 {
    for (groups) |group| if (std.mem.eql(u8, group.name, name)) return group.files;
    unreachable;
}

fn readSource(a: Allocator, io: Io, root: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ root, name });
    return Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
}

fn existsSource(a: Allocator, io: Io, root: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(a, &.{ root, name });
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "expand only the supported OCaml source-list syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars = std.StringHashMap([]const u8).init(a);
    try vars.put("items", "one.ml two.mli");
    const actual = try expand(a, &vars, "$(addprefix dir/, $(items)) $(addprefix other/, three.ml)", 0);
    try std.testing.expectEqualStrings("dir/one.ml dir/two.mli  other/three.ml ", actual);
    try std.testing.expectError(error.InvalidMakeExpression, expand(a, &vars, "$(addprefix a/, $(items)", 0));
}

test "dependency rules retain backend and subdirectory context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rules: std.ArrayList(Dependency) = .empty;
    try parseDepend(a, "a.cmx : \\\n  b.cmx \\\n  c.cmi\nifeq \"$(ARCH)\" \"arm64\"\narch.cmx : a.cmx\nendif\n", "stdlib/.depend", &rules);
    try std.testing.expectEqual(@as(usize, 2), rules.items.len);
    try std.testing.expectEqualStrings("stdlib/a.cmx", rules.items[0].output);
    try std.testing.expectEqualStrings("stdlib/c.cmi", rules.items[0].prerequisites[1]);
    try std.testing.expectEqualStrings("arm64", rules.items[1].arch.?);
}
