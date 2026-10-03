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
        if (args.len < 5) return error.InvalidArguments;
        var substitutions = std.StringHashMap([]const u8).init(gpa);
        for (args[3 .. args.len - 1]) |pair| {
            const equal = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidArguments;
            if (equal == 0) return error.InvalidArguments;
            try substitutions.put(pair[0..equal], pair[equal + 1 ..]);
        }
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
