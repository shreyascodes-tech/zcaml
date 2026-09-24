const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    const input_file_path = args.next() orelse {
        std.log.err("usage: replace-all <input> <output> <substitutions-json>", .{});
        return error.InvalidArguments;
    };
    const output_file_path = args.next() orelse {
        std.log.err("missing output file path", .{});
        return error.InvalidArguments;
    };
    const substitutions = args.next() orelse {
        std.log.err("missing substitutions array", .{});
        return error.InvalidArguments;
    };

    const input_file = try Io.Dir.cwd().readFileAlloc(io, input_file_path, gpa, .unlimited);
    defer gpa.free(input_file);

    const substitutions_parsed = std.json.parseFromSlice([]Substitution, gpa, substitutions, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.log.err("Invalid substitution input, it must be of type  Array<{{ literal_pattern: string, replacement: string, occurances?: number }}>", .{});
        return error.InvalidSubstitution;
    };
    defer substitutions_parsed.deinit();
    const subs = substitutions_parsed.value;

    const remaining = try gpa.alloc(u32, subs.len);
    defer gpa.free(remaining);
    for (subs, remaining) |sub, *r| r.* = sub.occurances;

    const output_file = try Io.Dir.cwd().createFile(io, output_file_path, .{});
    defer output_file.close(io);

    var write_buf: [64 * 1024]u8 = undefined;
    var file_writer = output_file.writer(io, &write_buf);
    const writer = &file_writer.interface;

    var rest: []const u8 = input_file;
    while (true) {
        // Find the earliest match among substitutions that still have budget.
        // Ties go to the substitution listed first.  Only the substitution
        // that is actually applied consumes one of its occurances.
        var best_idx: usize = rest.len;
        var best: ?usize = null;
        for (subs, remaining, 0..) |sub, r, i| {
            if (r == 0 or sub.literal_pattern.len == 0) continue;
            const idx = std.mem.indexOf(u8, rest, sub.literal_pattern) orelse continue;
            if (idx < best_idx) {
                best_idx = idx;
                best = i;
            }
        }

        const i = best orelse break;
        try writer.writeAll(rest[0..best_idx]);
        try writer.writeAll(subs[i].replacement);
        rest = rest[best_idx + subs[i].literal_pattern.len ..];
        remaining[i] -= 1;
    }
    try writer.writeAll(rest);
    try writer.flush();
}

const Substitution = struct {
    literal_pattern: []const u8,
    replacement: []const u8,
    occurances: u32 = std.math.maxInt(u32),
};
