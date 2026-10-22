const std = @import("std");
const Ocaml = @import("build/ocaml.zig");
const Tools = @import("build/tools/root.zig");

pub const OcamlVersion = enum {
    @"5.5.1",
    @"5.4.1",
    @"5.3.0",
    @"5.2.1",
    @"5.1.1",
    @"5.0.0",

    pub fn dependencyName(self: OcamlVersion) []const u8 {
        return switch (self) {
            .@"5.5.1" => "ocaml_5_5_1",
            .@"5.4.1" => "ocaml_5_4_1",
            .@"5.3.0" => "ocaml_5_3_0",
            .@"5.2.1" => "ocaml_5_2_1",
            .@"5.1.1" => "ocaml_5_1_1",
            .@"5.0.0" => "ocaml_5_0_0",
        };
    }
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    if (b.option(bool, "ocaml", "build ocaml") orelse false) {
        const ocaml_version = b.option(OcamlVersion, "ocaml-version", "ocaml version to build") orelse .@"5.5.1";

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

        if (b.lazyDependency(ocaml_version.dependencyName(), .{})) |ocaml_dep| {
            const prefix = b.option([]const u8, "ocaml-prefix", "install sub-prefix under zig-out") orelse b.fmt(
                "{s}/host-{s}/target-{s}",
                .{
                    @tagName(ocaml_version),
                    try compiler_host.result.linuxTriple(b.allocator),
                    try compiler_target.result.linuxTriple(b.allocator),
                },
            );

            const ocaml = Ocaml.init(b, ocaml_dep);

            const toolchain = try ocaml.build(.{
                .compiler_host = compiler_host,
                .compiler_target = compiler_target,
                .optimize = optimize,
                .prefix = prefix,
            });

            toolchain.addInstall(b.getInstallStep(), .{
                .prefix = prefix,
            });
        }

        return;
    }
}
