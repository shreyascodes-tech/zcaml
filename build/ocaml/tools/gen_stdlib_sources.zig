//! Module-alias-expanded copies of the stdlib sources (what upstream's
//! `stdlib/Makefile` produces with `expand_module_aliases.awk`).
const std = @import("std");
const utils = @import("utils.zig");
const InputDir = utils.InputDir;
const OutputDir = utils.OutputDir;

const GenStdlibSources = @This();

ocaml_src_dir: InputDir,
expanded_dir: OutputDir,

/// Written to `expanded_dir/<same relative path>` (see `Manifest.Src.expanded`).
const files_to_expand = [_][]const u8{
    "stdlib/stdlib.mli",
    "stdlib/stdlib.ml",
    "stdlib/arrayLabels.mli",
    "stdlib/listLabels.mli",
    "stdlib/bytesLabels.mli",
    "stdlib/stringLabels.mli",
    "stdlib/moreLabels.mli",
    "stdlib/stdLabels.mli",
    "otherlibs/unix/unixLabels.mli",
};

pub fn run(self: *GenStdlibSources, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var root_dir = try self.ocaml_src_dir.open(io, .{});
    defer root_dir.close(io);

    var exp_dir = try self.expanded_dir.open(io, .{});
    defer exp_dir.close(io);

    for (files_to_expand) |rel| {
        const raw = try root_dir.readFileAlloc(io, rel, gpa, .unlimited);
        defer gpa.free(raw);
        const expanded = try expandModuleAliases(arena, std.fs.path.basename(rel), raw);
        if (std.fs.path.dirname(rel)) |dir| try exp_dir.createDirPath(io, dir);
        try exp_dir.writeFile(io, .{ .sub_path = rel, .data = expanded });
    }
}

fn expandModuleAliases(
    arena: std.mem.Allocator,
    filename: []const u8,
    src: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "# 1 \"{s}\"\n", .{filename});

    const is_labels = std.mem.endsWith(u8, filename, "Labels.mli");
    var in_aliases = false;

    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        if (!first) {
            try out.append(arena, '\n');
        }
        first = false;

        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "(*MODULE_ALIASES*)")) {
            in_aliases = true;
            try out.appendSlice(arena, line);
            continue;
        }

        if (is_labels) {
            if (try rewriteLabelsSinceLine(arena, line)) |rewritten| {
                try out.appendSlice(arena, rewritten);
                continue;
            }
        }

        if (in_aliases) {
            if (try rewriteModuleAliasLine(arena, line)) |rewritten| {
                try out.appendSlice(arena, rewritten);
                continue;
            }
        }

        try out.appendSlice(arena, line);
    }

    return out.items;
}

fn rewriteLabelsSinceLine(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const since_idx = std.mem.indexOf(u8, line, "@since ") orelse return null;
    const after_since = line[since_idx + "@since ".len ..];
    const in_idx = std.mem.indexOf(u8, after_since, " in ") orelse return null;
    const open_paren_rel = std.mem.lastIndexOfScalar(u8, after_since[0..in_idx], '(') orelse return null;
    if (open_paren_rel == 0 or after_since[open_paren_rel - 1] != ' ') return null;
    const close_paren_rel = std.mem.indexOfScalarPos(u8, after_since, in_idx + 4, ')') orelse return null;

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, line[0 .. since_idx + "@since ".len + open_paren_rel - 1]);
    try buf.appendSlice(arena, after_since[close_paren_rel + 1 ..]);
    return buf.items;
}

fn rewriteModuleAliasLine(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const tok1 = it.next() orelse return null;
    if (!std.mem.eql(u8, tok1, "module")) return null;
    const mod_name = it.next() orelse return null;
    const eq_tok = it.next() orelse return null;
    if (!std.mem.eql(u8, eq_tok, "=")) return null;
    const target_mod = it.next() orelse return null;

    return try std.fmt.allocPrint(
        arena,
        "\n(** @canonical Stdlib.{s} *)\nmodule {s} = Stdlib__{s}",
        .{ mod_name, mod_name, target_mod },
    );
}
