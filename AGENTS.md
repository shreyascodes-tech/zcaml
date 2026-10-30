This is a Zig 0.17+ project (see build.zig.zon). Do not assume APIs from Zig 0.15/0.16 or older still apply.

use zig env to get the lib dir and look into the source for new apis.

## Zig 0.17 notes

- Enum/integer conversion builtins changed: use `@backingInt(value)` instead of `@intFromEnum(value)`, and `@fromBackingInt(integer)` instead of `@enumFromInt(integer)`. The result type is inferred from context; cast the integer when needed (e.g. `const v: Version = @fromBackingInt(@as(u8, 0));`).
- Struct reflection no longer exposes a `.fields` array of field records. `@typeInfo(T).@"struct"` has parallel `field_names`, `field_types`, and `field_attrs` slices. Use `std.meta.fieldNames(T)` when only names are needed. Prefer `@FieldType(T, name)` when only a field's type is needed.
- Field defaults live in field attributes and require the field type: `info.field_attrs[i].defaultValue(info.field_types[i])`. Existing code using `std.meta.fieldInfo(T, field)` must use `field_info.attrs.defaultValue(field_info.type)`, not `field_info.defaultValue()`. `std.meta.fieldInfo` itself is deprecated in favor of `@typeInfo`.

## I/O and process APIs

./zig-pkg/ is the new place where zig puts the extracted dependencies.

Zig now uses the new std.Io interface, std.process.Init (juicy main) for basic Io and argument/env access respectively.

example code showcasing the new APIs (please read the src for more info):
```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // allocators
    const gpa = init.gpa;
    const arena_alloc = init.arena.allocator();
    _ = arena_alloc;

    // args
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // skip the program name

    // reading files (a)
    const input_file = blk: {
        const input_file_path = args.next() orelse {
            std.log.err("missing input file", .{});
            return error.MissingInputFile;
        };

        if (std.mem.eql(u8, input_file_path, "-")) {
            break :blk std.Io.File.stdin();
        }

        break :blk try std.Io.Dir.cwd().openFile(io, input_file_path, .{});
    };
    defer input_file.close(io);

    const input_file_contents = blk: {
        var reader = input_file.reader(io, &.{});
        const input_file_contents = try reader.interface.allocRemaining(gpa, .unlimited);
        break :blk input_file_contents;
    };
    defer gpa.free(input_file_contents);

    // reading files (b)
    const another_input_file = blk: {
        const another_input_file_path = args.next() orelse {
            std.log.err("missing another input file", .{});
            return error.MissingAnotherInputFile;
        };

        // checkout readFileAllocOptions for more advanced options or reading with a sentinel etc
        break :blk try std.Io.Dir.cwd().readFileAlloc(io, another_input_file_path, gpa, .unlimited);
    };
    defer gpa.free(another_input_file);

    const output_file = blk: {
        const output_file_path = args.next() orelse {
            std.log.err("missing output file", .{});
            return error.MissingOutputFile;
        };

        if (std.mem.eql(u8, output_file_path, "-")) {
            break :blk std.Io.File.stdout();
        }

        break :blk try std.Io.Dir.cwd().createFile(io, output_file_path, .{});
    };
    defer output_file.close(io);

    // writing files (basic)
    try output_file.writeStreamingAll(io, "Another simple case\n");

    // writing files (streaming)
    var write_buffer: [1024]u8 = undefined;
    var file_writer = output_file.writer(io, &write_buffer);
    const writer = &file_writer.interface;

    try writer.writeAll("hello world\n");
    try writer.print("hello {s}\n", .{"world"});

    // more advanced stuff
    var input_file_reader = input_file.reader(io, &.{});
    _ = try writer.sendFileAll(&input_file_reader, .unlimited);

    // must flush at the end
    try file_writer.flush();
}
```

NEVER commit without explicit user confirmation.
