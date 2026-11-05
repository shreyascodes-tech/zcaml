//! `zcaml-cc-<target>`: the C compiler of a toolchain (`ocamlc -config`'s `c_compiler`).
//!
//! Runs `zig cc` with the target's flags baked in, followed by its own arguments.
//! `c_compiler` has to be a single program: tools like dune split it into a program
//! and flags and don't always pass the flags (and pass them twice when they do), so
//! `zig cc -target ...` doesn't work there. The name is unique per target so the
//! wrappers of several toolchains can be on `PATH` at once.
//!
//! The `zig` run is `$ZIG` if set, otherwise `zig` from `PATH`.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, init.environ_map.get("ZIG") orelse "zig");
    try argv.append(arena, "cc");
    try argv.appendSlice(arena, options.args);
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    while (args.next()) |arg| try argv.append(arena, arg);

    if (builtin.os.tag != .windows) {
        const err = std.process.replace(io, .{ .argv = argv.items });
        std.log.err("could not run {s}: {t}", .{ argv.items[0], err });
        return 127;
    }

    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| {
        std.log.err("could not run {s}: {t}", .{ argv.items[0], err });
        return 127;
    };
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
    };
}
