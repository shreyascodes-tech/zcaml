const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4 and args.len != 5) return error.InvalidArguments;

    const source = try Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .unlimited);
    const file = try Io.Dir.cwd().createFile(init.io, args[args.len - 1], .{});
    defer file.close(init.io);

    var buffer: [8192]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    const out = &writer.interface;

    if (std.mem.eql(u8, args[1], "copy")) {
        try out.writeAll(source);
    } else if (std.mem.eql(u8, args[1], "sys")) {
        if (args.len != 5) return error.InvalidArguments;

        const raw_version = try Io.Dir.cwd().readFileAlloc(init.io, args[3], allocator, .unlimited);
        const version = std.mem.trim(u8, std.mem.sliceTo(raw_version, '\n'), " \t\r\n");
        var parts = std.mem.splitScalar(u8, version, '.');
        const major = parts.next() orelse return error.InvalidVersion;
        const minor = parts.next() orelse return error.InvalidVersion;
        const patch = parts.next() orelse return error.InvalidVersion;

        const Substitution = struct {
            key: []const u8,
            value: []const u8,
        };
        const substitutions = [_]Substitution{
            .{ .key = "@configure_input@", .value = "Generated from sys.ml.in" },
            .{ .key = "@VERSION@", .value = version },
            .{ .key = "@OCAML_DEVELOPMENT_VERSION@", .value = "false" },
            .{ .key = "@OCAML_VERSION_MAJOR@", .value = major },
            .{ .key = "@OCAML_VERSION_MINOR@", .value = minor },
            .{ .key = "@OCAML_VERSION_PATCHLEVEL@", .value = patch },
            .{ .key = "@OCAML_RELEASE_EXTRA@", .value = "None" },
        };

        var cursor: usize = 0;
        while (cursor < source.len) {
            if (source[cursor] == '@') {
                var replaced = false;

                for (substitutions) |substitution| {
                    if (std.mem.startsWith(u8, source[cursor..], substitution.key)) {
                        try out.writeAll(substitution.value);
                        cursor += substitution.key.len;
                        replaced = true;
                        break;
                    }
                }
                if (replaced) {
                    continue;
                }
            }

            try out.writeByte(source[cursor]);
            cursor += 1;
        }
    } else if (std.mem.eql(u8, args[1], "aliases")) {
        var lines = std.mem.splitScalar(u8, source, '\n');
        var state: enum { before, aliases } = .before;

        while (lines.next()) |line| {
            switch (state) {
                .before => {
                    if (std.mem.indexOf(u8, line, "(*MODULE_ALIASES*)") != null) {
                        state = .aliases;
                    } else {
                        try out.writeAll(line);
                        try out.writeByte('\n');
                    }
                },
                .aliases => {
                    var words = std.mem.tokenizeAny(u8, line, " \t\r");
                    if (words.next()) |first| {
                        if (std.mem.eql(u8, first, "module")) {
                            const name = words.next() orelse return error.InvalidAlias;
                            const equals = words.next() orelse "";
                            if (!std.mem.eql(u8, equals, "=")) {
                                return error.InvalidAlias;
                            }

                            const target = words.next() orelse return error.InvalidAlias;
                            try out.print(
                                "\n(** @canonical Stdlib.{s} *)\nmodule {s} = Stdlib__{s}\n",
                                .{ name, name, target },
                            );
                            continue;
                        }
                    }

                    try out.writeAll(line);
                    try out.writeByte('\n');
                },
            }
        }
        // *Labels interfaces have no marker: upstream AWK leaves their module
        // declarations intact (and only normalizes documentation annotations).
    } else {
        return error.InvalidArguments;
    }

    try writer.flush();
}
