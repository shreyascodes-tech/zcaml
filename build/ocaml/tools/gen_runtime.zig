//! Generated runtime sources (what upstream's `runtime/Makefile` produces):
//! the bytecode instruction tables and the C primitive table.
const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const OutputFile = utils.OutputFile;
const Allocating = std.Io.Writer.Allocating;

instruct_h: InputFile,
opnames_h: OutputFile,
jumptbl_h: OutputFile,
/// Scanned for `CAMLprim` definitions.
c_files: []const InputFile = &.{},
primitives: OutputFile,
prims_c: OutputFile,
opcodes_ml: OutputFile,
opcodes_mli: OutputFile,
opnames_ml: OutputFile,

const GenRuntime = @This();

pub fn run(self: *GenRuntime, init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const instruct_h = try self.instruct_h.readAll(io, arena);
    try self.opnames_h.writeAll(io, try opnamesH(arena, instruct_h));
    try self.jumptbl_h.writeAll(io, try jumptblH(arena, instruct_h));

    const prims = try scanPrimitives(io, arena, self.c_files);
    var primitives: Allocating = .init(arena);
    for (prims.names) |name| try primitives.writer.print("{s}\n", .{name});
    try self.primitives.writeAll(io, primitives.written());
    try self.prims_c.writeAll(io, try primsC(arena, prims));

    const opcodes = try parseOpcodes(arena, instruct_h);
    var opnames_ml: Allocating = .init(arena);
    try opnames_ml.writer.writeAll("let names_of_instructions = [|\n");
    for (opcodes) |op| try opnames_ml.writer.print("  \"{s}\";\n", .{op});
    try opnames_ml.writer.writeAll("|]\n");
    try self.opnames_ml.writeAll(io, opnames_ml.written());

    var opcodes_ml: Allocating = .init(arena);
    for (opcodes, 0..) |op, i| try opcodes_ml.writer.print("let op{s} = {d}\n", .{ op, i });
    try self.opcodes_ml.writeAll(io, opcodes_ml.written());

    var opcodes_mli: Allocating = .init(arena);
    for (opcodes) |op| try opcodes_mli.writer.print("val op{s} : int\n", .{op});
    try self.opcodes_mli.writeAll(io, opcodes_mli.written());
}

/// `names_of_<enum>[]` string tables for the enums in `instruct.h`.
fn opnamesH(arena: std.mem.Allocator, instruct_h: []const u8) ![]const u8 {
    var out: Allocating = .init(arena);
    const w = &out.writer;

    var lines = std.mem.splitScalar(u8, instruct_h, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.indexOf(u8, line, "/*") != null) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "enum ")) {
            try w.writeAll("static char const * const names_of_");
            const after_enum = line["enum ".len..];
            if (std.mem.endsWith(u8, after_enum, "{")) {
                try w.print("{s}[] = {{\n", .{after_enum[0 .. after_enum.len - 1]});
            } else {
                try w.print("{s}\n", .{after_enum});
            }
            continue;
        }

        // Quote every `[A-Z][A-Z_0-9]*` identifier.
        var i: usize = 0;
        while (i < line.len) {
            if (std.ascii.isUpper(line[i])) {
                const start = i;
                i += 1;
                while (i < line.len and (std.ascii.isUpper(line[i]) or std.ascii.isDigit(line[i]) or line[i] == '_')) : (i += 1) {}
                try w.print("\"{s}\"", .{line[start..i]});
            } else {
                try w.writeByte(line[i]);
                i += 1;
            }
        }
        try w.writeByte('\n');
    }
    return out.written();
}

/// The threaded-code jump table (`&&lbl_<OPCODE>` for every instruction).
fn jumptblH(arena: std.mem.Allocator, instruct_h: []const u8) ![]const u8 {
    var out: Allocating = .init(arena);
    const w = &out.writer;

    var lines = std.mem.splitScalar(u8, instruct_h, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "}")) break;
        if (!std.mem.startsWith(u8, line, "  ")) continue;

        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == ' ' and i + 1 < line.len and std.ascii.isUpper(line[i + 1])) {
                try w.print(" &&lbl_{c}", .{line[i + 1]});
                i += 2;
            } else {
                try w.writeByte(line[i]);
                i += 1;
            }
        }
        try w.writeByte('\n');
    }
    return out.written();
}

const Primitives = struct {
    /// Sorted and deduplicated.
    names: []const []const u8,
    /// `CAMLextern value <prim>(...);` for every `CAMLprim` definition.
    extern_decls: []const u8,
};

fn scanPrimitives(io: std.Io, arena: std.mem.Allocator, c_files: []const InputFile) !Primitives {
    const prefix = "CAMLprim value ";
    var names: std.ArrayList([]const u8) = .empty;
    var extern_decls: std.ArrayList(u8) = .empty;

    for (c_files) |c_file| {
        const src = try c_file.readAll(io, arena);
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
                    try names.append(arena, rest[0..end]);
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
                const open_idx = std.mem.indexOfScalar(u8, line, '(') orelse continue;
                const close_idx = std.mem.indexOfScalarPos(u8, line, open_idx + 1, ')') orelse continue;
                const op = line[open_idx + 1 .. close_idx];
                try names.append(arena, try std.fmt.allocPrint(arena, "caml_int64_{s}", .{op}));
                try names.append(arena, try std.fmt.allocPrint(arena, "caml_int64_{s}_native", .{op}));
            }
        }
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var unique: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        if (unique.items.len == 0 or !std.mem.eql(u8, unique.getLast(), name)) {
            try unique.append(arena, name);
        }
    }
    return .{ .names = unique.items, .extern_decls = extern_decls.items };
}

fn primsC(arena: std.mem.Allocator, prims: Primitives) ![]const u8 {
    var out: Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(
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
    try w.writeAll(prims.extern_decls);
    try w.writeAll("\nconst c_primitive caml_builtin_cprim[] = {\n");
    for (prims.names) |name| try w.print("  (c_primitive) {s},\n", .{name});
    try w.writeAll("  0 };\n\nconst char * const caml_names_of_builtin_cprim[] = {\n");
    for (prims.names) |name| try w.print("  \"{s}\",\n", .{name});
    try w.writeAll(
        \\  0 };
        \\
        \\const enum caml_byte_program_mode caml_byte_program_mode = STANDARD;
        \\const char_os *caml_runtime_standard_library_default = OCAML_STDLIB_DIR;
        \\
    );
    return out.written();
}

/// The members of `enum instructions`, in order.
fn parseOpcodes(arena: std.mem.Allocator, instruct_h: []const u8) ![]const []const u8 {
    const enum_pos = std.mem.indexOf(u8, instruct_h, "enum instructions") orelse return error.InstructionsEnumNotFound;
    const brace_pos = std.mem.indexOfScalarPos(u8, instruct_h, enum_pos, '{') orelse return error.InstructionsBraceNotFound;
    var idx = brace_pos + 1;

    var opcodes: std.ArrayList([]const u8) = .empty;
    while (idx < instruct_h.len) {
        idx = try skipWhitespaceAndComments(instruct_h, idx);
        if (idx >= instruct_h.len or instruct_h[idx] == '}') break;

        if (std.ascii.isUpper(instruct_h[idx])) {
            const start = idx;
            idx += 1;
            while (idx < instruct_h.len and (std.ascii.isUpper(instruct_h[idx]) or std.ascii.isDigit(instruct_h[idx]) or instruct_h[idx] == '_')) : (idx += 1) {}
            const name = instruct_h[start..idx];

            idx = try skipWhitespaceAndComments(instruct_h, idx);
            if (idx < instruct_h.len and instruct_h[idx] == ',') {
                idx += 1;
                try opcodes.append(arena, name);
            } else if (idx < instruct_h.len and instruct_h[idx] == '}') {
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
