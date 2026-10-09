//! The compilation subset of stdlib/expand_module_aliases.awk.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Preprocessed = struct {
    text: []const u8,
    filename: []const u8,
    labels: bool = false,

    pub fn format(p: Preprocessed, w: *Writer) Writer.Error!void {
        try w.print("# 1 \"{s}\"\n", .{p.filename});

        var aliases = false;
        var lines = std.mem.splitScalar(u8, p.text, '\n');

        while (lines.next()) |raw| {
            // splitScalar yields an extra empty field after a final newline.
            if (raw.len == 0 and lines.index == null) break;

            const line = std.mem.trimEnd(u8, raw, "\r");

            if (!aliases and std.mem.indexOf(u8, line, "(*MODULE_ALIASES*)") != null) {
                aliases = true;
                continue;
            }

            if (aliases) {
                var words = std.mem.tokenizeAny(u8, line, " \t");

                if (std.mem.eql(u8, words.next() orelse "", "module")) {
                    const name = words.next() orelse "";
                    _ = words.next();
                    const target = words.next() orelse "";

                    try w.print("\n(** @canonical Stdlib.{s} *)\nmodule {s} = Stdlib__{s}\n", .{ name, name, target });
                    continue;
                }
            }

            if (!aliases and p.labels) {
                try writeLabelsLine(w, line);
            } else {
                try w.writeAll(line);
            }

            try w.writeByte('\n');
        }
    }
};

fn writeLabelsLine(w: *Writer, line: []const u8) Writer.Error!void {
    const since = std.mem.indexOf(u8, line, "@since ") orelse return w.writeAll(line);
    const start = since + "@since ".len;
    const open = std.mem.indexOfScalarPos(u8, line, start, '(') orelse return w.writeAll(line);

    if (open == start or line[open - 1] != ' ') return w.writeAll(line);

    try w.writeAll(line[0..start]);
    const rest = line[open + 1 ..];

    if (std.mem.indexOf(u8, rest, " in ")) |in| {
        if (std.mem.indexOfScalarPos(u8, rest, in, ')')) |close| {
            try w.writeAll(rest[0..in]);
            return w.writeAll(rest[close + 1 ..]);
        }
    }

    try w.writeAll(rest);
}

test "expand aliases and preserve attached attributes" {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);

    try w.print("{f}", .{Preprocessed{
        .filename = "stdlib.mli",
        .text = "val x : int\n(*MODULE_ALIASES*)\nmodule Foo = Foo\n[@@alert unstable]\n",
    }});

    try std.testing.expectEqualStrings(
        "# 1 \"stdlib.mli\"\nval x : int\n\n(** @canonical Stdlib.Foo *)\nmodule Foo = Stdlib__Foo\n[@@alert unstable]\n",
        w.buffered(),
    );
}

test "labels interfaces retain the labels-specific since version" {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);

    try w.print("{f}", .{Preprocessed{
        .filename = "arrayLabels.mli",
        .labels = true,
        .text = "(** @since 4.03 (4.05 in ArrayLabels) *)\n(** @since 5.0 *)\n",
    }});

    try std.testing.expectEqualStrings(
        "# 1 \"arrayLabels.mli\"\n(** @since 4.05 *)\n(** @since 5.0 *)\n",
        w.buffered(),
    );
}
