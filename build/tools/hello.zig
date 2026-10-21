const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const OutputFile = utils.OutputFile;

const Self = @This();

some_str: []const u8,
input_file: InputFile,
output_file: OutputFile,
opt_str: ?[]const u8 = null,
flag: bool = false,
list: []const []const u8 = &.{},
@"--": std.ArrayList([]const u8) = .empty,

pub fn run(self: *Self, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, self.input_file.path(), gpa, .unlimited);
    defer gpa.free(contents);

    const out_file = try std.Io.Dir.cwd().createFile(io, self.output_file.path(), .{});
    defer out_file.close(io);

    var write_buf: [1024]u8 = undefined;
    var file_writer = out_file.writer(io, &write_buf);
    const writer = &file_writer.interface;

    try writer.print("{s} (flag={}, list={d}, rest={d})\n{s}", .{
        self.some_str,
        self.flag,
        self.list.len,
        self.@"--".items.len,
        contents,
    });
    try file_writer.flush();
}
