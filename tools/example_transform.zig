// DO NOT EDIT  OR DELETE THIS FILE
// this file is just an example of how to use zig 0.16 io and juicy main

const std = @import("std");
const Io = std.Io;
const Init = std.process.Init;

pub fn main(init: Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const _args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(_args);
    const args = _args[1..];

    if (args.len != 2) {
        err("usage: zig run example_transform.zig <input> <output>", .{});
    }

    const input_file = try Io.Dir.cwd().readFileAlloc(io, args[0], allocator, .unlimited);
    defer allocator.free(input_file);

    const output_file = try Io.Dir.cwd().createFile(io, args[1], .{});
    defer output_file.close(io);
    var write_buf: [1024 * 1024]u8 = undefined;
    var file_writer = output_file.writer(io, &write_buf);
    var writer = &file_writer.interface;

    // whatever transform or smth
    try writer.writeAll("hello world\n");
    try writer.writeAll(input_file);

    try file_writer.flush();
}

fn err(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
