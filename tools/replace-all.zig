const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    const input_file_path = args.next() orelse {
        std.log.err("missing input file path", .{});
        return;
    };
    const output_file_path = args.next() orelse {
        std.log.err("missing output file path", .{});
        return;
    };
    const substitutions = args.next() orelse {
        std.log.err("missing substitutions array", .{});
        return;
    };

    const input_file = try Io.Dir.cwd().readFileAlloc(io, input_file_path, gpa, .unlimited);
    defer gpa.free(input_file);

    const output_file = try Io.Dir.cwd().createFile(io, output_file_path, .{});
    defer output_file.close(io);

    const substitutions_array_parsed = std.json.parseFromSlice([]Substitution, gpa, substitutions, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("Invalid substitution input, it must be of type  Array<{{ literal_pattern: string, replacement: string, occurances?: number }}>", .{});
        return error.InvalidSubstitution;
    };
    defer substitutions_array_parsed.deinit();
    const substitutions_array = substitutions_array_parsed.value;

    var write_buf: [1024 * 1024]u8 = undefined;
    var file_writer = output_file.writer(io, &write_buf);
    const writer = &file_writer.interface;

    var read_slice = input_file;

    var occurances_map = std.AutoHashMap(usize, u32).init(gpa);
    defer occurances_map.deinit();

    if (substitutions.len > 0) while (read_slice.len > 0) {
        var next_idx: usize = read_slice.len;
        var sub: ?Substitution = null;
        for (substitutions_array, 0..) |substitution, i| {
            const pattern = substitution.literal_pattern;
            if (pattern.len == 0 or pattern.len > next_idx) continue;

            const idx = std.mem.indexOf(u8, read_slice[0..next_idx], pattern) orelse continue;

            const occurances_gop = try occurances_map.getOrPut(i);
            const occurances = if (occurances_gop.found_existing) occurances_gop.value_ptr.* else blk: {
                occurances_gop.value_ptr.* = 0;
                break :blk 0;
            };
            const max_occurances = substitution.occurances;
            if (occurances >= max_occurances) continue;
            occurances_gop.value_ptr.* += 1;

            next_idx = idx;
            sub = substitution;
        }

        try writer.writeAll(read_slice[0..next_idx]);
        if (sub) |substitution| {
            try writer.writeAll(substitution.replacement);
            read_slice = read_slice[next_idx + substitution.literal_pattern.len ..];
        } else break;
    };

    try writer.flush();
}

const Substitution = struct {
    literal_pattern: []const u8,
    replacement: []const u8,
    occurances: u32 = std.math.maxInt(u32),
};
