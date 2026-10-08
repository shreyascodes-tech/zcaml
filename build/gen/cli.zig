//! Shared plumbing for `ocaml-gen` subcommands.

const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;

/// Logs the message and returns the sentinel `main` turns into `exit(1)`.
pub fn fail(comptime fmt: []const u8, fmt_args: anytype) error{Reported} {
    std.log.err(fmt, fmt_args);
    return error.Reported;
}

/// `--name value` parsing driven by the field types of `T`:
///
///   - `bool`                 flag
///   - `?[]const u8`          optional
///   - `[]const u8`           required; declare it `= undefined`
///   - `[]const []const u8`   positional arguments; at most one such field
///
/// Field `foo_bar` is `--foo-bar`; a trailing `_` is dropped (`asm_` → `--asm`).
pub fn parseArgs(
    comptime T: type,
    gpa: std.mem.Allocator,
    args: *std.process.Args.Iterator,
) (error{ Reported, OutOfMemory })!T {
    const Field = std.meta.FieldEnum(T);
    const fields = @typeInfo(T).@"struct".fields;
    var result: T = .{};
    var seen: std.EnumSet(Field) = .initEmpty();
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            try positional.append(gpa, arg);
            continue;
        }
        const name = arg[2..];

        inline for (fields) |f| {
            if (f.type != []const []const u8 and std.mem.eql(u8, name, optionName(f.name))) {
                seen.insert(@field(Field, f.name));
                @field(result, f.name) = if (f.type == bool) true else blk: {
                    const value = args.next() orelse return fail("--{s} requires a value", .{name});
                    break :blk switch (f.type) {
                        []const u8, ?[]const u8 => value,
                        else => @compileError("unsupported option type " ++ @typeName(f.type)),
                    };
                };
                break;
            }
        } else return fail("unknown option '--{s}'", .{name});
    }

    var has_positional = false;
    inline for (fields) |f| {
        if (f.type == []const u8 and !seen.contains(@field(Field, f.name)))
            return fail("missing required option '--{s}'", .{optionName(f.name)});
        if (f.type == []const []const u8) {
            @field(result, f.name) = try positional.toOwnedSlice(gpa);
            has_positional = true;
        }
    }
    if (!has_positional and positional.items.len != 0)
        return fail("unexpected argument '{s}'", .{positional.items[0]});
    return result;
}

fn optionName(comptime field: []const u8) []const u8 {
    comptime var buf: [field.len]u8 = undefined;
    comptime var len = 0;
    comptime {
        for (field) |c| {
            buf[len] = if (c == '_') '-' else c;
            len += 1;
        }
        if (len > 0 and buf[len - 1] == '-') len -= 1;
    }
    const result = buf[0..len].*;
    return &result;
}

/// An output tree; every generated file goes through here.
pub const Out = struct {
    io: Io,
    dir: Io.Dir,

    pub fn open(io: Io, path: []const u8) !Out {
        const dir = Io.Dir.cwd().createDirPathOpen(io, path, .{}) catch |err|
            return fail("{s}: {t}", .{ path, err });
        return .{ .io = io, .dir = dir };
    }

    pub fn close(o: Out) void {
        o.dir.close(o.io);
    }

    /// `<out>/<path>`, parents created. Call `finish` when done.
    pub fn create(o: Out, path: []const u8) !File {
        if (std.fs.path.dirname(path)) |dir| try o.dir.createDirPath(o.io, dir);
        return .{ .io = o.io, .file = try o.dir.createFile(o.io, path, .{}) };
    }

    /// Writes `{f}` of `value` to `<out>/<path>`.
    pub fn write(o: Out, path: []const u8, value: anytype) !void {
        var f = try o.create(path);
        defer f.close();
        try f.writer().print("{f}", .{value});
        try f.finish();
    }

    pub const File = struct {
        io: Io,
        file: Io.File,
        buf: [64 * 1024]u8 = undefined,
        fw: ?Io.File.Writer = null,

        pub fn writer(f: *File) *Writer {
            if (f.fw == null) f.fw = f.file.writer(f.io, &f.buf);
            return &f.fw.?.interface;
        }

        pub fn finish(f: *File) !void {
            if (f.fw) |*fw| try fw.interface.flush();
        }

        pub fn close(f: *File) void {
            f.file.close(f.io);
        }
    };
};
