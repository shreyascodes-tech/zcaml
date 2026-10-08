//! `ocaml-gen primitives`: derives `runtime/primitives`, `runtime/prims.c` and
//! the two generated runtime headers from the runtime's C sources.

const std = @import("std");
const Io = std.Io;

const gen = @import("../gen.zig");
const primitives = @import("../primitives.zig");
const sources = @import("../sources.zig");
const fail = gen.fail;

const Args = struct {
    src: []const u8 = undefined,
    out: []const u8 = undefined,
    /// Selects `win32.c` over `unix.c`.
    win32: bool = false,
};

pub fn run(io: Io, gpa: std.mem.Allocator, argv: *std.process.Args.Iterator) !void {
    const args = try gen.parseArgs(Args, argv);

    // The primitive table is the bytecode runtime's: `ocamlopt` resolves
    // primitives at link time, so only `ocamlrun` needs the dispatch tables.
    const files = if (args.win32)
        sources.runtime(.bytecode, .win32)
    else
        sources.runtime(.bytecode, .unix);

    // The scanned names borrow from the sources, so every source has to stay
    // live until the output is written.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scanner: primitives.Scanner = .{};
    for (files) |file| {
        const source = try gen.readSrc(io, arena, args.src, "runtime", file);
        try scanner.scan(arena, source);
    }
    const names = scanner.finish();

    const instruct = try gen.readSrc(io, arena, args.src, "runtime/caml", "instruct.h");

    const out = try Io.Dir.cwd().createDirPathOpen(io, args.out, .{});
    defer out.close(io);

    try gen.writeFile(io, out, "runtime/primitives", primitives.writePrimitives, .{names});
    try gen.writeFile(io, out, "runtime/prims.c", primitives.writePrimsC, .{ names, scanner.decls.items });
    try gen.writeFile(io, out, "runtime/caml/opnames.h", primitives.writeOpnames, .{instruct});
    try gen.writeFile(io, out, "runtime/caml/jumptbl.h", primitives.writeJumptbl, .{instruct});
}
