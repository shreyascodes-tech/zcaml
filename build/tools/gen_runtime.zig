const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const OutputFile = utils.OutputFile;

const Self = @This();

instruct_h: InputFile,
opnames_h: OutputFile,
jumptbl_h: OutputFile,
primitives: OutputFile,
prims_c: OutputFile,
c_files: []const InputFile = &.{},
opcodes_ml: OutputFile,
opcodes_mli: OutputFile,
opnames_ml: OutputFile,

pub fn run(self: *Self, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const instruct_src = try self.instruct_h.readAll(io, gpa);
    defer gpa.free(instruct_src);

    try self.writeOpnamesH(io, instruct_src);
    try self.writeJumptblH(io, instruct_src);
    try self.writePrimitivesAndPrimsC(io, gpa);
    try self.writeOpcodes(io, gpa, instruct_src);
}

fn writeOpnamesH(self: *Self, io: std.Io, instruct_src: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var file_writer = try self.opnames_h.writer(io, &write_buf);
    defer file_writer.file.close(io);
    const writer = &file_writer.interface;

    var lines = std.mem.splitScalar(u8, instruct_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.indexOf(u8, line, "/*") != null) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "enum ")) {
            try writer.writeAll("static char const * const names_of_");
            const after_enum = line["enum ".len..];
            if (std.mem.endsWith(u8, after_enum, "{")) {
                try writer.writeAll(after_enum[0 .. after_enum.len - 1]);
                try writer.writeAll("[] = {\n");
            } else {
                try writer.writeAll(after_enum);
                try writer.writeByte('\n');
            }
            continue;
        }

        // Replace [A-Z][A-Z_0-9]* with quoted strings
        var i: usize = 0;
        while (i < line.len) {
            if (std.ascii.isUpper(line[i])) {
                const start = i;
                i += 1;
                while (i < line.len and (std.ascii.isUpper(line[i]) or std.ascii.isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
                try writer.print("\"{s}\"", .{line[start..i]});
            } else {
                try writer.writeByte(line[i]);
                i += 1;
            }
        }
        try writer.writeByte('\n');
    }

    try file_writer.flush();
}

fn writeJumptblH(self: *Self, io: std.Io, instruct_src: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var file_writer = try self.jumptbl_h.writer(io, &write_buf);
    defer file_writer.file.close(io);
    const writer = &file_writer.interface;

    var lines = std.mem.splitScalar(u8, instruct_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "}")) break;
        if (!std.mem.startsWith(u8, line, "  ")) continue;

        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == ' ' and i + 1 < line.len and std.ascii.isUpper(line[i + 1])) {
                try writer.writeAll(" &&lbl_");
                try writer.writeByte(line[i + 1]);
                i += 2;
            } else {
                try writer.writeByte(line[i]);
                i += 1;
            }
        }
        try writer.writeByte('\n');
    }

    try file_writer.flush();
}

fn writePrimitivesAndPrimsC(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prim_names: std.ArrayList([]const u8) = .empty;
    var extern_decls: std.ArrayList(u8) = .empty;

    const prefix = "CAMLprim value ";

    for (self.c_files) |c_file| {
        const src = try c_file.readAll(io, gpa);
        defer gpa.free(src);

        var in_multiline_decl = false;
        var lines = std.mem.splitScalar(u8, src, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (in_multiline_decl) {
                if (std.mem.indexOfScalar(u8, line, ')')) |close_idx| {
                    try extern_decls.appendSlice(arena, line[0..close_idx]);
                    try extern_decls.appendSlice(arena, ");\n");
                    in_multiline_decl = false;
                } else {
                    try extern_decls.appendSlice(arena, line);
                    try extern_decls.append(arena, '\n');
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, prefix)) {
                const rest = line[prefix.len..];
                if (rest.len > 0 and std.ascii.isLower(rest[0])) {
                    var end: usize = 1;
                    while (end < rest.len and (std.ascii.isLower(rest[end]) or std.ascii.isDigit(rest[end]) or rest[end] == '_')) : (end += 1) {}
                    try prim_names.append(arena, try arena.dupe(u8, rest[0..end]));
                }

                try extern_decls.appendSlice(arena, "CAMLextern value ");
                if (std.mem.indexOfScalar(u8, rest, ')')) |close_idx| {
                    try extern_decls.appendSlice(arena, rest[0..close_idx]);
                    try extern_decls.appendSlice(arena, ");\n");
                } else {
                    try extern_decls.appendSlice(arena, rest);
                    try extern_decls.append(arena, '\n');
                    in_multiline_decl = true;
                }
            } else if (std.mem.startsWith(u8, line, "CAMLprim_int64_")) {
                if (std.mem.indexOfScalar(u8, line, '(')) |open_idx| {
                    if (std.mem.indexOfScalarPos(u8, line, open_idx + 1, ')')) |close_idx| {
                        const op = line[open_idx + 1 .. close_idx];
                        try prim_names.append(arena, try std.fmt.allocPrint(arena, "caml_int64_{s}", .{op}));
                        try prim_names.append(arena, try std.fmt.allocPrint(arena, "caml_int64_{s}_native", .{op}));
                    }
                }
            }
        }
    }

    std.mem.sort([]const u8, prim_names.items, {}, lessThanSlice);

    var unique_prims: std.ArrayList([]const u8) = .empty;
    for (prim_names.items) |name| {
        if (unique_prims.items.len == 0 or !std.mem.eql(u8, unique_prims.items[unique_prims.items.len - 1], name)) {
            try unique_prims.append(arena, name);
        }
    }

    // Write runtime/primitives
    {
        var write_buf: [4096]u8 = undefined;
        var file_writer = try self.primitives.writer(io, &write_buf);
        defer file_writer.file.close(io);
        const writer = &file_writer.interface;

        for (unique_prims.items) |name| {
            try writer.print("{s}\n", .{name});
        }
        try file_writer.flush();
    }

    // Write runtime/prims.c
    {
        var write_buf: [4096]u8 = undefined;
        var file_writer = try self.prims_c.writer(io, &write_buf);
        defer file_writer.file.close(io);
        const writer = &file_writer.interface;

        try writer.writeAll(
            \\/* Generated file, do not edit */
            \\
            \\#define CAML_INTERNALS
            \\#include "caml/mlvalues.h"
            \\#include "caml/prims.h"
            \\#include "caml/startup.h"
            \\#include "build_config.h"
            \\
            \\
        );
        try writer.writeAll(extern_decls.items);
        try writer.writeAll("\nconst c_primitive caml_builtin_cprim[] = {\n");
        for (unique_prims.items) |name| {
            try writer.print("  (c_primitive) {s},\n", .{name});
        }
        try writer.writeAll("  0 };\n\nconst char * const caml_names_of_builtin_cprim[] = {\n");
        for (unique_prims.items) |name| {
            try writer.print("  \"{s}\",\n", .{name});
        }
        try writer.writeAll(
            \\  0 };
            \\
            \\const enum caml_byte_program_mode caml_byte_program_mode = STANDARD;
            \\const char_os *caml_runtime_standard_library_default = OCAML_STDLIB_DIR;
            \\
        );

        try file_writer.flush();
    }
}

fn writeOpcodes(self: *Self, io: std.Io, gpa: std.mem.Allocator, instruct_src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opcodes = try parseOpcodes(arena, instruct_src);

    // opnames.ml
    {
        var write_buf: [4096]u8 = undefined;
        var file_writer = try self.opnames_ml.writer(io, &write_buf);
        defer file_writer.file.close(io);
        const writer = &file_writer.interface;

        try writer.writeAll("let names_of_instructions = [|\n");
        for (opcodes) |op| {
            try writer.print("  \"{s}\";\n", .{op});
        }
        try writer.writeAll("|]\n");
        try file_writer.flush();
    }

    // opcodes.ml
    {
        var write_buf: [4096]u8 = undefined;
        var file_writer = try self.opcodes_ml.writer(io, &write_buf);
        defer file_writer.file.close(io);
        const writer = &file_writer.interface;

        for (opcodes, 0..) |op, i| {
            try writer.print("let op{s} = {d}\n", .{ op, i });
        }
        try file_writer.flush();
    }

    // opcodes.mli
    {
        var write_buf: [4096]u8 = undefined;
        var file_writer = try self.opcodes_mli.writer(io, &write_buf);
        defer file_writer.file.close(io);
        const writer = &file_writer.interface;

        for (opcodes) |op| {
            try writer.print("val op{s} : int\n", .{op});
        }
        try file_writer.flush();
    }
}

fn parseOpcodes(arena: std.mem.Allocator, instruct_src: []const u8) ![]const []const u8 {
    const enum_pos = std.mem.indexOf(u8, instruct_src, "enum instructions") orelse return error.InstructionsEnumNotFound;
    const brace_pos = std.mem.indexOfScalarPos(u8, instruct_src, enum_pos, '{') orelse return error.InstructionsBraceNotFound;
    var idx = brace_pos + 1;

    var opcodes: std.ArrayList([]const u8) = .empty;

    while (idx < instruct_src.len) {
        idx = try skipWhitespaceAndComments(instruct_src, idx);
        if (idx >= instruct_src.len or instruct_src[idx] == '}') break;

        if (std.ascii.isUpper(instruct_src[idx])) {
            const start = idx;
            idx += 1;
            while (idx < instruct_src.len and (std.ascii.isUpper(instruct_src[idx]) or std.ascii.isDigit(instruct_src[idx]) or instruct_src[idx] == '_')) : (idx += 1) {}
            const name = instruct_src[start..idx];

            idx = try skipWhitespaceAndComments(instruct_src, idx);

            if (idx < instruct_src.len and instruct_src[idx] == ',') {
                idx += 1;
                try opcodes.append(arena, name);
            } else if (idx < instruct_src.len and instruct_src[idx] == '}') {
                break;
            }
        } else {
            idx += 1;
        }
    }

    return opcodes.items;
}

fn skipWhitespaceAndComments(src: []const u8, start_idx: usize) !usize {
    var idx = start_idx;
    while (idx < src.len and (std.ascii.isWhitespace(src[idx]) or src[idx] == '/')) {
        if (src[idx] == '/' and idx + 1 < src.len and src[idx + 1] == '*') {
            const close_comment = std.mem.indexOfPos(u8, src, idx + 2, "*/") orelse return error.UnterminatedComment;
            idx = close_comment + 2;
        } else {
            idx += 1;
        }
    }
    return idx;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
