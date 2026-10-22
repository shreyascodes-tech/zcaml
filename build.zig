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

    pub fn slug(self: OcamlVersion, b: *std.Build) ![]const u8 {
        return std.mem.replaceOwned(u8, b.allocator, @tagName(self), ".", "_");
    }

    pub fn dependencyName(self: OcamlVersion, b: *std.Build) ![]const u8 {
        return b.fmt("ocaml_{s}", .{try self.slug(b)});
    }
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const gen_step = b.step("generate", "generate OCaml version manifests from upstream Makefiles");
    const update_src = b.addUpdateSourceFiles();
    for (std.enums.values(OcamlVersion)) |ver| {
        if (b.lazyDependency(try ver.dependencyName(b), .{})) |dep| {
            const file_name = b.fmt("v{s}.zon", .{try ver.slug(b)});
            var cmd = Tools.Command{
                .gen_manifests = .{
                    .ocaml_src_dir = .of(dep.path("")),
                    .out_file = .of(file_name),
                },
            };
            _ = cmd.run(b);
            update_src.addCopyFileToSource(
                cmd.gen_manifests.out_file.lazyPath(),
                b.fmt("build/manifests/{s}", .{file_name}),
            );
        }
    }
    gen_step.dependOn(&update_src.step);

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

        if (b.lazyDependency(try ocaml_version.dependencyName(b), .{})) |ocaml_dep| {
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
