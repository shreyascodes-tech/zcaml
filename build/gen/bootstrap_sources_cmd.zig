//! Prepare coldstart stdlib inputs without modifying the dependency tree.

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");
const stdlib = @import("stdlib.zig");

const Args = struct {
    src: []const u8,
    out: []const u8,
    sys_ml: []const u8,
    launcher: []const u8,
    modules: []const []const u8 = &.{},
};

pub fn run(io: Io, gpa: std.mem.Allocator, argv: *std.process.Args.Iterator) !void {
    const args = try cli.parseArgs(Args, gpa, argv);
    defer gpa.free(args.modules);

    if (args.modules.len == 0) return cli.fail("no stdlib modules given", .{});

    for (args.modules) |module| {
        if (module.len == 0) return cli.fail("empty stdlib module name", .{});

        for (module) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                return cli.fail("invalid stdlib module name '{s}'", .{module});
            }
        }
    }

    const src = Io.Dir.cwd().openDir(io, args.src, .{}) catch |err|
        return cli.fail("{s}: {t}", .{ args.src, err });
    defer src.close(io);

    const out = try cli.Out.open(io, args.out);
    defer out.close();

    for (args.modules) |module| {
        for ([_][]const u8{ "ml", "mli" }) |ext| {
            const filename = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ module, ext });
            defer gpa.free(filename);

            const path = try std.fmt.allocPrint(gpa, "stdlib/{s}", .{filename});
            defer gpa.free(path);

            const text = if (std.mem.eql(u8, filename, "sys.ml"))
                Io.Dir.cwd().readFileAlloc(io, args.sys_ml, gpa, .unlimited) catch |err|
                    return cli.fail("{s}: {t}", .{ args.sys_ml, err })
            else
                src.readFileAlloc(io, path, gpa, .unlimited) catch |err|
                    return cli.fail("{s}/{s}: {t}", .{ args.src, path, err });
            defer gpa.free(text);

            var file = try out.create(filename);
            defer file.close();

            if (std.mem.eql(u8, module, "stdlib") or (std.mem.endsWith(u8, module, "Labels") and std.mem.eql(u8, ext, "mli"))) {
                try file.writer().print("{f}", .{stdlib.Preprocessed{
                    .text = text,
                    .filename = filename,
                    .labels = std.mem.endsWith(u8, module, "Labels"),
                }});
            } else {
                try file.writer().writeAll(text);
            }

            try file.finish();
        }
    }

    {
        const launcher = Io.Dir.cwd().readFileAlloc(io, args.launcher, gpa, .unlimited) catch |err|
            return cli.fail("{s}: {t}", .{ args.launcher, err });
        defer gpa.free(launcher);

        var file = try out.create("runtime-launch-info");
        defer file.close();

        // The boot compiler has suffixing disabled (utils/config.fixed.ml).
        try file.writer().writeByte(0);
        try file.writer().writeAll(launcher);
        try file.finish();
    }
}
