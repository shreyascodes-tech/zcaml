//! Name a generated OCaml source `name` (its path as upstream compiles it): a
//! leading line directive, and the generator's own directives pointing at its
//! output (as ocamllex and ocamlyacc write them) renamed. Locations, debug
//! info and digests then don't depend on the cache directory it was generated in.
const std = @import("std");
const utils = @import("utils.zig");

input: utils.InputFile,
name: []const u8,
output: utils.OutputFile,

const NameSource = @This();

pub fn run(self: *NameSource, init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const src = try self.input.readAll(io, arena);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "# 1 \"{s}\"\n", .{self.name});
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (directiveLine(line)) |line_num| {
            const path = line[std.mem.indexOfScalar(u8, line, '"').? + 1 .. line.len - 1];
            if (std.mem.endsWith(u8, path, ".ml") or std.mem.endsWith(u8, path, ".mli")) {
                try out.print(arena, "# {s} \"{s}\"", .{ line_num, self.name });
            } else {
                try out.appendSlice(arena, line);
            }
        } else {
            try out.appendSlice(arena, line);
        }
        if (lines.peek() != null) try out.append(arena, '\n');
    }
    try self.output.writeAll(io, out.items);
}

/// The line number of a `# <n> "<path>"` directive.
fn directiveLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "# ") or !std.mem.endsWith(u8, line, "\"")) return null;
    const rest = line[2..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const num = rest[0..space];
    if (num.len == 0) return null;
    for (num) |c| if (!std.ascii.isDigit(c)) return null;
    if (rest.len < space + 3 or rest[space + 1] != '"') return null;
    return num;
}
