//! `with-path <dir> <program> <args>...`: runs `program` with `dir` in front of `PATH`.
//!
//! Build steps get generated directories as arguments, not in their environment:
//! this is how the compilers run during the build find the build machine's
//! `zcaml-cc-<target>`, which `Config`'s commands (assembling, linking) name.
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("usage: with-path <dir> <program> <args>...", .{});
        std.process.exit(2);
    }

    var env = try init.environ_map.clone(arena);
    const sep = if (builtin.os.tag == .windows) ";" else ":";
    const path = init.environ_map.get("PATH") orelse "";
    try env.put("PATH", try std.mem.concat(arena, u8, &.{ args[1], sep, path }));

    const argv = args[2..];
    if (builtin.os.tag == .windows) {
        var child = try std.process.spawn(init.io, .{ .argv = argv, .environ_map = &env });
        const term = try child.wait(init.io);
        std.process.exit(switch (term) {
            .exited => |code| code,
            else => 1,
        });
    }
    return std.process.replace(init.io, .{ .argv = argv, .environ_map = &env });
}
