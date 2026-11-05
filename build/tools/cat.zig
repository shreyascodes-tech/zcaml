//! Concatenate `inputs` into `output`.
const std = @import("std");
const utils = @import("utils.zig");

inputs: []const utils.InputFile,
output: utils.OutputFile,

const Cat = @This();

pub fn run(self: *Cat, init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    for (self.inputs) |in| try out.appendSlice(arena, try in.readAll(io, arena));
    try self.output.writeAll(io, out.items);
}
