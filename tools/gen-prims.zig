const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) {
        std.log.err("usage: gen-prims <output.c> <source.c>...", .{});
        return error.InvalidArguments;
    }

    var names: std.ArrayList([]const u8) = .empty;
    for (args[2..]) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16 * 1024 * 1024));
        const prefix = "CAMLprim value ";
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, source, search_start, prefix)) |start| {
            var name_start = start + prefix.len;
            while (name_start < source.len and (source[name_start] == ' ' or source[name_start] == '\t')) {
                name_start += 1;
            }

            var name_end = name_start;
            while (name_end < source.len and (source[name_end] == '_' or std.ascii.isAlphanumeric(source[name_end]))) {
                name_end += 1;
            }

            if (name_end > name_start) {
                try names.append(allocator, source[name_start..name_end]);
            }
            search_start = name_end;
        }
    }

    std.mem.sort([]const u8, names.items, {}, lessThanString);
    var unique: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        if (unique.items.len == 0 or !std.mem.eql(u8, unique.items[unique.items.len - 1], name)) {
            try unique.append(allocator, name);
        }
    }

    const output_file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    defer output_file.close(init.io);

    var write_buf: [1024 * 1024]u8 = undefined;
    var file_writer = output_file.writer(init.io, &write_buf);
    const writer = &file_writer.interface;

    try writer.writeAll("/* Generated file, do not edit */\n\n");
    try writer.writeAll("#define CAML_INTERNALS\n");
    try writer.writeAll("#include \"caml/mlvalues.h\"\n");
    try writer.writeAll("#include \"caml/prims.h\"\n");
    try writer.writeAll("#include \"caml/startup.h\"\n");
    try writer.writeAll("#include \"build_config.h\"\n\n");

    for (unique.items) |name| {
        try writer.print("CAMLextern value {s}();\n", .{name});
    }

    try writer.writeAll("\nconst c_primitive caml_builtin_cprim[] = {\n");
    for (unique.items) |name| {
        try writer.print("  (c_primitive) &{s},\n", .{name});
    }
    try writer.writeAll("  0 };\n\n");

    try writer.writeAll("const char * const caml_names_of_builtin_cprim[] = {\n");
    for (unique.items) |name| {
        try writer.print("  \"{s}\",\n", .{name});
    }
    try writer.writeAll("  0 };\n\n");

    try writer.writeAll("const enum caml_byte_program_mode caml_byte_program_mode = STANDARD;\n");
    try writer.writeAll("const char_os *caml_runtime_standard_library_default = OCAML_STDLIB_DIR;\n");
    try writer.flush();
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
