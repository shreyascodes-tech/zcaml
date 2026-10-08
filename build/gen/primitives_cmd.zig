//! `ocaml-gen primitives`.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const prims = @import("prims.zig");

const Args = struct {
    src: []const u8 = undefined,
    out: []const u8 = undefined,
    /// `runtime_BYTECODE_C_SOURCES`, relative to `--src`, in Makefile order.
    files: []const []const u8 = &.{},
};

pub fn run(io: Io, gpa: std.mem.Allocator, argv: *std.process.Args.Iterator) !void {
    const args = try cli.parseArgs(Args, gpa, argv);
    defer gpa.free(args.files);
    if (args.files.len == 0) return cli.fail("no source files given", .{});

    // Scanned names borrow from the sources.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = Io.Dir.cwd().openDir(io, args.src, .{}) catch |err|
        return cli.fail("{s}: {t}", .{ args.src, err });
    defer src.close(io);

    var scanner: prims.Scanner = .{};
    for (args.files) |file| {
        try scanner.scan(arena, try readSrc(io, arena, src, args.src, file));
    }
    const names = scanner.finish();

    const instruct = try readSrc(io, arena, src, args.src, "runtime/caml/instruct.h");

    const out = try cli.Out.open(io, args.out);
    defer out.close();

    try out.write("runtime/primitives", prims.Primitives{ .names = names });
    try out.write("runtime/prims.c", prims.PrimsC{ .names = names, .decls = scanner.decls.items });
    try out.write("runtime/caml/opnames.h", prims.Opnames{ .header = instruct });
    try out.write("runtime/caml/jumptbl.h", prims.Jumptbl{ .header = instruct });
}

fn readSrc(io: Io, gpa: std.mem.Allocator, src: Io.Dir, src_path: []const u8, path: []const u8) ![]u8 {
    return src.readFileAlloc(io, path, gpa, .unlimited) catch |err|
        return cli.fail("{s}/{s}: {t}", .{ src_path, path, err });
}
