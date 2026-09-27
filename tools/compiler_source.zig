const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 4) return error.InvalidArguments;

    const mode = args[1];
    const input = try Io.Dir.cwd().readFileAlloc(init.io, args[2], gpa, .unlimited);

    const file = try Io.Dir.cwd().createFile(init.io, args[args.len - 1], .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    const out = &writer.interface;

    if (std.mem.eql(u8, mode, "copy")) {
        try out.writeAll(input);
    } else if (std.mem.eql(u8, mode, "concat")) {
        const second = try Io.Dir.cwd().readFileAlloc(init.io, args[3], gpa, .unlimited);
        try out.writeAll(input);
        try out.writeAll("\n");
        try out.writeAll(second);
    } else if (std.mem.eql(u8, mode, "menhir")) {
        try replaceAll(out, input, "MenhirLib", "CamlinternalMenhirLib");
    } else if (std.mem.eql(u8, mode, "menhir-interface")) {
        try out.writeAll("[@@@ocaml.warning \"-67\"]\n");
        try out.writeAll(input);
    } else if (std.mem.eql(u8, mode, "runtimedef")) {
        const primitives = try Io.Dir.cwd().readFileAlloc(init.io, args[3], gpa, .unlimited);
        try out.writeAll("let builtin_exceptions = [|\n");
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |line| {
            const marker = std.mem.indexOf(u8, line, "/* \"") orelse continue;
            const name = line[marker + 4 ..];
            const end = std.mem.indexOfScalar(u8, name, '"') orelse continue;
            try out.print("  \"{s}\";\n", .{name[0..end]});
        }
        try out.writeAll("|]\nlet builtin_primitives = [|\n");
        var names = std.mem.tokenizeScalar(u8, primitives, '\n');
        while (names.next()) |name| try out.print("  \"{s}\";\n", .{name});
        try out.writeAll("|]\n");
    } else if (std.mem.eql(u8, mode, "opcodes") or std.mem.eql(u8, mode, "opcodes-interface")) {
        const start = std.mem.indexOf(u8, input, "enum instructions {") orelse return error.MissingOpcodeEnum;
        const end = std.mem.indexOfScalarPos(u8, input, start, '}') orelse return error.MissingOpcodeEnum;
        var tokens = std.mem.tokenizeAny(u8, input[start + "enum instructions {".len .. end], " \n\t\r,");
        var number: usize = 0;
        while (tokens.next()) |name| {
            if (std.mem.eql(u8, name, "FIRST_UNIMPLEMENTED_OP")) break;
            if (std.mem.eql(u8, mode, "opcodes")) {
                try out.print("let op{s} = {d}\n", .{ name, number });
            } else {
                try out.print("val op{s} : int\n", .{name});
            }
            number += 1;
        }
    } else if (std.mem.eql(u8, mode, "config-common")) {
        if (args.len != 6) return error.InvalidArguments;
        const prefix = args[3];
        const version = args[4];
        const kinds = [_]struct { name: []const u8, letter: []const u8 }{
            .{ .name = "EXEC", .letter = "X" },     .{ .name = "CMI", .letter = "I" },
            .{ .name = "CMO", .letter = "O" },      .{ .name = "CMA", .letter = "A" },
            .{ .name = "CMX", .letter = "Y" },      .{ .name = "CMXA", .letter = "Z" },
            .{ .name = "AST_IMPL", .letter = "M" }, .{ .name = "AST_INTF", .letter = "N" },
            .{ .name = "CMXS", .letter = "D" },     .{ .name = "CMT", .letter = "T" },
            .{ .name = "LINEAR", .letter = "L" },
        };
        var substitutions = std.StringHashMap([]const u8).init(gpa);
        try substitutions.put("configure_input", "Generated from config.common.ml.in");
        for (kinds) |kind| {
            const key = try std.fmt.allocPrint(gpa, "{s}_MAGIC_NUMBER", .{kind.name});
            const value = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix, kind.letter, version });
            try substitutions.put(key, value);
        }
        try substitute(out, input, &substitutions);
    } else if (std.mem.eql(u8, mode, "config-generated")) {
        if (args.len != 5) return error.InvalidArguments;
        var substitutions = std.StringHashMap([]const u8).init(gpa);
        for (config_values) |entry| try substitutions.put(entry.key, entry.value);
        try substitutions.put("ocaml_bindir", args[3]);
        try substitutions.put("TARGET_BINDIR", args[3]);
        try substitute(out, input, &substitutions);
    } else {
        return error.InvalidArguments;
    }

    try writer.flush();
}

fn replaceAll(out: *Io.Writer, input: []const u8, from: []const u8, to: []const u8) !void {
    var rest = input;
    while (std.mem.indexOf(u8, rest, from)) |at| {
        try out.writeAll(rest[0..at]);
        try out.writeAll(to);
        rest = rest[at + from.len ..];
    }
    try out.writeAll(rest);
}

fn substitute(out: *Io.Writer, input: []const u8, values: *const std.StringHashMap([]const u8)) !void {
    var rest = input;
    while (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        try out.writeAll(rest[0..at]);
        const suffix = rest[at + 1 ..];
        const end = std.mem.indexOfScalar(u8, suffix, '@') orelse return error.UnterminatedSubstitution;
        const key = suffix[0..end];
        const value = values.get(key) orelse {
            std.log.err("unknown OCaml configuration variable @{s}@", .{key});
            return error.UnknownSubstitution;
        };
        try out.writeAll(value);
        rest = suffix[end + 1 ..];
    }
    try out.writeAll(rest);
}

const ConfigValue = struct { key: []const u8, value: []const u8 };
// Linux x86_64 bytecode-only target. Values describing unavailable native
// compilation or unconfigured external tools must not imply their presence.
const config_values = [_]ConfigValue{
    .{ .key = "configure_input", .value = "Generated from config.generated.ml.in" },
    .{ .key = "QS", .value = "" },
    .{ .key = "ocaml_bindir", .value = "bin" },
    .{ .key = "TARGET_BINDIR", .value = "bin" },
    .{ .key = "ccomp_type", .value = "cc" },
    .{ .key = "CC", .value = "zig cc" },
    .{ .key = "ocaml_cc_vendor", .value = "clang" },
    .{ .key = "outputobj", .value = "-o " },
    .{ .key = "cc_has_debug_prefix_map", .value = "true" },
    .{ .key = "ocaml_cv_prog_as_debug_prefix_map", .value = "false" },
    .{ .key = "as_is_cc", .value = "true" },
    .{ .key = "bytecode_cflags", .value = "-std=gnu11 -fwrapv" },
    .{ .key = "bytecode_cppflags", .value = "" },
    .{ .key = "native_cflags", .value = "" },
    .{ .key = "native_cppflags", .value = "" },
    .{ .key = "zstd_libs", .value = "" },
    .{ .key = "cclibs", .value = "-lm -lpthread -ldl" },
    .{ .key = "native_ldflags", .value = "" },
    .{ .key = "with_nonexecstack_note", .value = "false" },
    .{ .key = "PACKLD", .value = "" },
    .{ .key = "rpath", .value = "" },
    .{ .key = "mksharedlibrpath", .value = "" },
    .{ .key = "AR", .value = "zig ar" },
    .{ .key = "supports_shared_libraries", .value = "false" },
    .{ .key = "natdynlink", .value = "false" },
    .{ .key = "mkdll_exp", .value = "" },
    .{ .key = "mkexe_exp", .value = "" },
    .{ .key = "mkmaindll_exp", .value = "" },
    .{ .key = "flambda", .value = "false" },
    .{ .key = "flambda_invariants", .value = "false" },
    .{ .key = "cmm_invariants", .value = "false" },
    .{ .key = "codegen_invariants", .value = "false" },
    .{ .key = "windows_unicode", .value = "0" },
    .{ .key = "flat_float_array", .value = "true" },
    .{ .key = "align_double", .value = "true" },
    .{ .key = "align_int64", .value = "true" },
    .{ .key = "function_sections", .value = "false" },
    .{ .key = "afl", .value = "false" },
    .{ .key = "bytecode_runtime_id", .value = "" },
    .{ .key = "native_runtime_id", .value = "" },
    .{ .key = "native_compiler", .value = "false" },
    .{ .key = "arch", .value = "none" },
    .{ .key = "model", .value = "default" },
    .{ .key = "system", .value = "linux" },
    .{ .key = "target_os_type", .value = "Unix" },
    .{ .key = "AS", .value = "zig cc" },
    .{ .key = "asm_cfi_supported", .value = "false" },
    .{ .key = "asm_size_type_directives", .value = "false" },
    .{ .key = "asm_dwarf_version", .value = "None" },
    .{ .key = "frame_pointers", .value = "false" },
    .{ .key = "reserved_header_bits", .value = "0" },
    .{ .key = "EXEEXT", .value = "" },
    .{ .key = "OBJEXT", .value = "o" },
    .{ .key = "S", .value = "s" },
    .{ .key = "libext", .value = "a" },
    .{ .key = "SO", .value = "so" },
    .{ .key = "host", .value = "x86_64-unknown-linux-gnu" },
    .{ .key = "target", .value = "x86_64-unknown-linux-gnu" },
    .{ .key = "systhread_support", .value = "true" },
    .{ .key = "flexdll_dir", .value = "" },
    .{ .key = "ar_supports_response_files", .value = "true" },
    .{ .key = "tsan", .value = "false" },
    .{ .key = "shebangscripts", .value = "true" },
    .{ .key = "suffixing", .value = "false" },
    .{ .key = "launch_method_target", .value = "sh" },
    .{ .key = "runtime_search_target", .value = "disable" },
};
