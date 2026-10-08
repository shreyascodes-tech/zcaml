//! Build-time code generator for the OCaml source tree.
//!
//! Replaces the parts of OCaml's build system that are shell, sed, awk, cpp or
//! autoconf. Each subcommand reads from an unmodified OCaml source tree and
//! writes a directory of generated files.
//!
//!     ocaml-gen configure --src DIR --out DIR --target TRIPLE [...]
//!     ocaml-gen primitives --src DIR --out DIR

const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;

const configure_cmd = @import("gen/configure_cmd.zig");
const primitives_cmd = @import("gen/primitives_cmd.zig");

const Command = enum {
    configure,
    primitives,

    const usage =
        \\usage: ocaml-gen COMMAND [options]
        \\
        \\commands:
        \\  configure    render the templates ./configure would have rendered
        \\  primitives   derive runtime/primitives, prims.c, opnames.h, jumptbl.h
        \\
    ;
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    run(io, gpa, &args) catch |err| switch (err) {
        // Already reported by `fail`; a stack trace would only be noise.
        error.Reported => std.process.exit(1),
        else => |e| return e,
    };
}

fn run(io: Io, gpa: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const command_name = args.next() orelse return fail("missing command\n{s}", .{Command.usage});
    const command = std.meta.stringToEnum(Command, command_name) orelse
        return fail("unknown command '{s}'\n{s}", .{ command_name, Command.usage });

    switch (command) {
        .configure => try configure_cmd.run(io, gpa, args),
        .primitives => try primitives_cmd.run(io, gpa, args),
    }
}

/// Reads `<src>/<dir>/<name>`, reporting the full path on failure.
pub fn readSrc(
    io: Io,
    gpa: std.mem.Allocator,
    src: []const u8,
    dir: []const u8,
    name: []const u8,
) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ src, dir, name }) catch
        return fail("path too long: {s}/{s}/{s}", .{ src, dir, name });
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err|
        return fail("{s}: {t}", .{ path, err });
}

/// Creates `<out>/<path>`, including any missing parent directories.
pub fn create(io: Io, out: Io.Dir, path: []const u8) !Io.File {
    if (std.fs.path.dirname(path)) |dir| try out.createDirPath(io, dir);
    return out.createFile(io, path, .{});
}

/// Calls `render(writer, args...)` with its output going to `<out>/<path>`.
pub fn writeFile(
    io: Io,
    out: Io.Dir,
    path: []const u8,
    comptime render: anytype,
    render_args: anytype,
) !void {
    var file = try create(io, out, path);
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    try @call(.auto, render, .{&fw.interface} ++ render_args);
    try fw.interface.flush();
}

pub fn fail(comptime fmt: []const u8, fmt_args: anytype) error{Reported} {
    std.log.err(fmt, fmt_args);
    return error.Reported;
}

/// Minimal `--name value` parsing. A field's type says how it is handled:
///
///   - `bool`           a flag, set by its presence alone
///   - `?[]const u8`    optional, defaults to null
///   - `[]const u8`     required; declare it `= undefined`
pub fn parseArgs(comptime T: type, args: *std.process.Args.Iterator) error{Reported}!T {
    const fields = @typeInfo(T).@"struct".fields;
    var result: T = .{};
    var seen: std.EnumSet(std.meta.FieldEnum(T)) = .initEmpty();

    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) return fail("expected an option, found '{s}'", .{arg});
        const name = arg[2..];

        inline for (fields) |f| {
            if (std.mem.eql(u8, name, optionName(f.name))) {
                seen.insert(@field(std.meta.FieldEnum(T), f.name));
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

    inline for (fields) |f| {
        if (f.type == []const u8 and !seen.contains(@field(std.meta.FieldEnum(T), f.name)))
            return fail("missing required option '--{s}'", .{optionName(f.name)});
    }
    return result;
}

/// Field names map to options with `_` replaced by `-`, so that `asm_` and
/// `cc_vendor` become `--asm` and `--cc-vendor`.
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
