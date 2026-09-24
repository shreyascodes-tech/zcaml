const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const output_path = args.next() orelse {
        std.log.err("missing output file path", .{});
        return error.InvalidArguments;
    };
    const input_path = args.next() orelse {
        std.log.err("missing input file path", .{});
        return error.InvalidArguments;
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        input_path,
        allocator,
        .unlimited,
    );

    var labels: std.ArrayList([]const u8) = .empty;
    var in_instructions = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (!in_instructions) {
            if (std.mem.indexOf(u8, line, "enum instructions") != null) in_instructions = true;
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "}")) break;
        if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) continue;

        var fields = std.mem.splitScalar(u8, line, ',');
        while (fields.next()) |field| {
            const name = std.mem.trim(u8, field, " \t\r");
            if (name.len == 0) continue;
            try labels.append(allocator, name);
        }
    }

    const output_file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer output_file.close(init.io);

    var write_buf: [1024 * 1024]u8 = undefined;
    var file_writer = output_file.writer(init.io, &write_buf);
    const writer = &file_writer.interface;

    for (labels.items) |label| {
        try writer.print("  &&lbl_{s},\n", .{label});
    }
    try writer.flush();
}
