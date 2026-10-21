const std = @import("std");
const Ocaml = @import("build/ocaml.zig");
const Tools = @import("build/tools/root.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    var hello_cmd = Tools.Command{ .hello = .{
        .input_file = "hello.txt",
        .output_file = "hello.txt",
        .some_str = "some string",
    } };
    b.getInstallStep().dependOn(&hello_cmd.run(b).step);

    if (b.option(bool, "ocaml", "build ocaml") orelse false) {
        const compiler_host = host: {
            const str = b.option([]const u8, "ocaml-host", "ocaml host") orelse {
                std.log.err("missing ocaml compiler host", .{});
                return error.MissingCompilerHost;
            };

            break :host Ocaml.resolveTarget(str);
        };

        const compiler_target = target: {
            const str = b.option([]const u8, "ocaml-target", "ocaml target") orelse break :target compiler_host;
            break :target Ocaml.resolveTarget(str);
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
