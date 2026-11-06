//! Bootstraps dune for a target: `boot/bootstrap.ml`'s two steps, run directly.
//!
//! ```text
//! tool <dune-src> <host-toolchain> <target-toolchain> <target-os> <out-file>
//! ```
//!
//! `boot/duneboot.ml` builds `_boot/dune.exe`, the binary dune releases, with the
//! first `ocamlc`/`ocamlopt` on `PATH`: the target toolchain's. It runs in the host
//! toolchain's toplevel, which `bootstrap.ml` would look up on `PATH` too, so this
//! does what it does with the host's `ocamllex` and `ocaml`.
//!
//! The bootstrap takes no compiler flags, but `ocamlopt` reads `OCAMLPARAM` (`ocamlFlags`).
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
    if (args.len != 6) fatal("usage: tool <dune-src> <host-toolchain> <target-toolchain> <target-os> <out-file>", .{});
    // Absolute: the commands run in `work`.
    const cwd = try std.process.currentPathAlloc(io, arena);
    const src = try path.resolve(arena, &.{ cwd, args[1] });
    const host_bin = try path.resolve(arena, &.{ cwd, args[2], "bin" });
    const target_bin = try path.resolve(arena, &.{ cwd, args[3], "bin" });
    const os = std.meta.stringToEnum(std.Target.Os.Tag, args[4]) orelse fatal("unknown OS '{s}'", .{args[4]});
    const out = try path.resolve(arena, &.{ cwd, args[5] });

    const work = try path.join(arena, &.{ path.dirname(out).?, "work" });
    Dir.cwd().deleteTree(io, work) catch {};
    try copyTree(io, arena, src, work);
    defer Dir.cwd().deleteTree(io, work) catch {};
    try setVersion(io, arena, work);

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
    if (try ocamlFlags(io, arena, os)) |flags| try env.put("OCAMLPARAM", flags);
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

/// What `dune subst` does for releases, so `dune --version` isn't `n/a`: the bootstrap
/// takes the version from `(version <v>)` in `dune-project`. The source is a release
/// commit, whose `CHANGES.md` starts with its version: `3.24.2 (2026-08-03)`.
fn setVersion(io: Io, arena: std.mem.Allocator, work: []const u8) !void {
    const changes = try Dir.cwd().readFileAlloc(io, try path.join(arena, &.{ work, "CHANGES.md" }), arena, .unlimited);
    var lines = std.mem.tokenizeScalar(u8, changes, '\n');
    const version = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "<!--")) continue;
        const v = line[0 .. std.mem.findScalar(u8, line, ' ') orelse line.len];
        _ = std.SemanticVersion.parse(v) catch fatal("CHANGES.md starts with '{s}', not a release: pin dune to a release commit", .{line});
        break v;
    } else fatal("CHANGES.md has no release", .{});

    const project_path = try path.join(arena, &.{ work, "dune-project" });
    const project = try Dir.cwd().readFileAlloc(io, project_path, arena, .unlimited);
    try Dir.cwd().writeFile(io, .{ .sub_path = project_path, .data = try std.fmt.allocPrint(arena, "{s}\n(version {s})\n", .{ project, version }) });
}

/// `OCAMLPARAM` for the bootstrap's `ocamlopt` runs, if any.
///
/// - `-s`: a stripped binary, ~25% smaller; OCaml backtraces need neither the
///   symbols nor DWARF. `-s` does nothing in compiles. Not on Windows, where the
///   linker is flexlink, without `-s`, and there is nothing to strip.
/// - macOS: the SDK's frameworks, for the file watcher's `CoreFoundation` and
///   `CoreServices`, which Zig doesn't ship: macOS dune is built on macOS. And
///   the SDK's headers after Zig's, for what Zig's lack: those the frameworks
///   include (`libDER/`), and the vendored `spawn`'s `sys/syscall.h`.
fn ocamlFlags(io: Io, arena: std.mem.Allocator, os: std.Target.Os.Tag) !?[]const u8 {
    if (os == .windows) return null;
    var flags: std.ArrayList(u8) = .empty;
    try flags.appendSlice(arena, "_,ccopt=-s");
    if (os == .macos) {
        if (builtin.os.tag != .macos) fatal("dune for macOS needs the macOS SDK's frameworks: bootstrap it on macOS", .{});
        const sdk = try std.process.run(arena, io, .{ .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" } });
        if (!sdk.term.success()) fatal("xcrun --show-sdk-path failed: {s}", .{sdk.stderr});
        const sdk_path = std.mem.trimEnd(u8, sdk.stdout, "\r\n");
        try flags.print(arena, ",ccopt=-F{s}/System/Library/Frameworks,ccopt=-idirafter{s}/usr/include", .{ sdk_path, sdk_path });
    }
    return flags.items;
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
