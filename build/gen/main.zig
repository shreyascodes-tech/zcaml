//! Replaces the parts of OCaml's build system that are shell, sed, awk, cpp
//! or autoconf. Each subcommand reads an unmodified OCaml tree and writes
//! generated files.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const configure_cmd = @import("configure_cmd.zig");
const primitives_cmd = @import("primitives_cmd.zig");
const sources_cmd = @import("sources_cmd.zig");
const bootstrap_sources_cmd = @import("bootstrap_sources_cmd.zig");

const Command = enum {
    configure,
    primitives,
    sources,
    @"bootstrap-sources",

    const usage =
        \\usage: ocaml-gen COMMAND [options]
        \\
        \\commands:
        \\  configure    render the templates ./configure would have rendered
        \\  primitives   derive runtime/primitives, prims.c, opnames.h, jumptbl.h
        \\  sources      extract the source lists from the Makefiles as zon
        \\  bootstrap-sources  prepare coldstart stdlib sources and launch info
        \\
    ;
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    run(init.io, init.gpa, &args) catch |err| switch (err) {
        error.Reported => std.process.exit(1),
        else => |e| return e,
    };
}

fn run(io: Io, gpa: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const command_name = args.next() orelse return cli.fail("missing command\n{s}", .{Command.usage});
    const command = std.meta.stringToEnum(Command, command_name) orelse
        return cli.fail("unknown command '{s}'\n{s}", .{ command_name, Command.usage });

    switch (command) {
        .configure => try configure_cmd.run(io, gpa, args),
        .primitives => try primitives_cmd.run(io, gpa, args),
        .sources => try sources_cmd.run(io, gpa, args),
        .@"bootstrap-sources" => try bootstrap_sources_cmd.run(io, gpa, args),
    }
}
