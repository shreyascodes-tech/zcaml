const std = @import("std");
const Ocaml = @import("build/ocaml.zig");
const Tools = @import("build/tools/root.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    var rest_args: std.ArrayList([]const u8) = .empty;
    try rest_args.appendSlice(b.allocator, &.{ "pos1", "pos2" });

    var hello_cmd = Tools.Command{ .hello = .{
        .input_file = .of(b.path("README.md")),
        .output_file = .of("hello.txt"),
        .some_str = "some string",
        .flag = true,
        .list = &.{ "a", "b", "c" },
        .@"--" = rest_args,
    } };
    _ = hello_cmd.run(b);
    b.getInstallStep().dependOn(&b.addInstallFile(hello_cmd.hello.output_file.lazyPath(), "hello.txt").step);

    if (b.option(bool, "ocaml", "build ocaml") orelse false) {
        const compiler_host = host: {
            const str = b.option([]const u8, "ocaml-host", "ocaml host") orelse {
                std.log.err("missing ocaml compiler host", .{});
                return error.MissingCompilerHost;
            };

            break :host Ocaml.resolveTarget(b, str);
        };

        const compiler_target = target: {
            const str = b.option([]const u8, "ocaml-target", "ocaml target") orelse break :target compiler_host;
            break :target Ocaml.resolveTarget(b, str);
        };

        const ocaml = Ocaml.init(b, b.dependency("ocaml", .{}));

        _ = try ocaml.build(.{
            .compiler_host = compiler_host,
            .compiler_target = compiler_target,
            .optimize = optimize,
        });

        return;
    }
}
