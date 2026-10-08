//! The `.depend` files `ocamldep` writes.

const std = @import("std");

pub const Rule = struct {
    target: []const u8,
    deps: []const []const u8,
};

/// Borrows from `text`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) error{ OutOfMemory, Malformed }![]const Rule {
    var rules: std.ArrayList(Rule) = .empty;
    var deps: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < text.len) {
        var target: ?[]const u8 = null;
        deps.clearRetainingCapacity();
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            var line = std.mem.trimEnd(u8, text[i..nl], "\r");
            i = @min(nl + 1, text.len);
            const continued = std.mem.endsWith(u8, line, "\\");
            if (continued) line = line[0 .. line.len - 1];

            var it = std.mem.tokenizeAny(u8, line, " \t");
            while (it.next()) |tok| {
                if (target == null) {
                    const t = std.mem.trimEnd(u8, tok, ":");
                    if (t.len == 0) return error.Malformed;
                    target = t;
                    continue;
                }
                if (std.mem.eql(u8, tok, ":")) continue;
                try deps.append(arena, tok);
            }
            if (!continued or i >= text.len) break;
        }
        if (target) |t| try rules.append(arena, .{
            .target = t,
            .deps = try arena.dupe([]const u8, deps.items),
        });
    }
    return rules.toOwnedSlice(arena);
}
