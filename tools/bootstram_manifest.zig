const std = @import("std");
const Manifest = @import("manifest.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const m = Manifest{
        .ocaml_version = "0.0.0",
        .release_number = 0,
        .magic_prefix = "todo",
        .magic_version = "todo",
        .exec_format = "todo",
        .source_hash = "todo",
        .source_groups = &.{},
        .backend_sources = &.{},
        .generated_files = &.{},
        .dependencies = &.{},
    };

    const path = "build/gen/manifest.zon";
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    const output = try std.Io.Dir.cwd().createFile(io, "build/gen/manifest.zon", .{});
    defer output.close(io);

    var output_write_buf: [1024]u8 = undefined;
    var output_writer = output.writer(io, &output_write_buf);
    const writer = &output_writer.interface;

    try std.zon.stringify.serialize(m, .{}, writer);

    try output_writer.flush();

    std.log.info("Manifest written to {s}.", .{path});

    std.log.info("Running zig build prepare...", .{});

    var prepare_run = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "zig", "build", "prepare" },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try prepare_run.wait(io);
}
