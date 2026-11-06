//! Bootstraps dune for a target: `boot/bootstrap.ml`'s two steps, run directly.
//!
//! ```text
//! tool <dune-src> <host-toolchain> <target-toolchain> <out-file>
//! ```
//!
//! `boot/duneboot.ml` builds `_boot/dune.exe`, the binary dune releases, with the
//! first `ocamlc`/`ocamlopt` on `PATH`: the target toolchain's. It runs in the host
//! toolchain's toplevel, which `bootstrap.ml` would look up on `PATH` too, so this
//! does what it does with the host's `ocamllex` and `ocaml`.
//!
//! The bootstrap writes into the source tree: it runs in a copy, next to `<out-file>`.
//! `zig` must be on `PATH`, for the toolchains' `zig cc`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const path = std.fs.path;

const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) fatal("usage: tool <dune-src> <host-toolchain> <target-toolchain> <out-file>", .{});
    // Absolute: the commands run in `work`.
    const cwd = try std.process.currentPathAlloc(io, arena);
    const src = try path.resolve(arena, &.{ cwd, args[1] });
    const host_bin = try path.resolve(arena, &.{ cwd, args[2], "bin" });
    const target_bin = try path.resolve(arena, &.{ cwd, args[3], "bin" });
    const out = try path.resolve(arena, &.{ cwd, args[4] });

    const work = try path.join(arena, &.{ path.dirname(out).?, "work" });
    Dir.cwd().deleteTree(io, work) catch {};
    try copyTree(io, arena, src, work);
    defer Dir.cwd().deleteTree(io, work) catch {};

    var env = try init.environ_map.clone(arena);
    try env.put("PATH", try std.mem.join(arena, if (builtin.os.tag == .windows) ";" else ":", &.{
        target_bin,
        host_bin,
        init.environ_map.get("PATH") orelse "",
    }));

    try run(io, arena, work, &env, &.{
        try path.join(arena, &.{ host_bin, "ocamllex" ++ exe_ext }),
        "-q",
        "-o",
        "boot/pps.ml",
        "boot/pps.mll",
    });
    // What `bootstrap.ml` feeds the toplevel (which resolves paths from the script's directory).
    var script: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "pps", "types", "libs" }) |m| try script.print(arena, "#mod_use \"{s}/boot/{s}.ml\";;\n", .{ work, m });
    try script.print(arena, "#use \"{s}/boot/duneboot.ml\";;\n", .{work});
    try Dir.cwd().writeFile(io, .{ .sub_path = try path.join(arena, &.{ work, "boot", "main.top" }), .data = script.items });
    try run(io, arena, work, &env, &.{
        try path.join(arena, &.{ host_bin, "ocaml" ++ exe_ext }),
        "-I",
        "+unix",
        "unix.cma",
        "boot/main.top",
    });

    // A copy, not a rename: `out` can't be inside `work`, which is removed.
    try Dir.copyFile(Dir.cwd(), try path.join(arena, &.{ work, "_boot", "dune.exe" }), Dir.cwd(), out, io, .{});
}

fn copyTree(io: Io, arena: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    var src_dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    try Dir.cwd().createDirPath(io, dest);
    var dest_dir = try Dir.cwd().openDir(io, dest, .{});
    defer dest_dir.close(io);

    var walker = try src_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest_dir.createDirPath(io, entry.path),
        .file => try Dir.copyFile(src_dir, entry.path, dest_dir, entry.path, io, .{}),
        else => {},
    };
}

fn run(io: Io, arena: std.mem.Allocator, cwd: []const u8, env: *const std.process.Environ.Map, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = env });
    const term = try child.wait(io);
    if (!term.success()) fatal("(cd {s} && {s}) failed: {any}", .{ cwd, try std.mem.join(arena, " ", argv), term });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
