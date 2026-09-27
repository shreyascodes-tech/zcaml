const std = @import("std");

pub fn build(b: *std.Build) !void {
    const prepare_exe = b.addExecutable(.{
        .name = "prepare-ocaml",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/prepare.zig"),
        }),
    });
    const prepare_run = b.addRunArtifact(prepare_exe);
    prepare_run.addDirectoryArg(b.dependency("ocaml", .{}).path("."));
    prepare_run.addArg(@import("build.zig.zon").dependencies.ocaml.hash);
    prepare_run.addArg("build/gen/manifest.zon");
    prepare_run.setCwd(b.path("."));
    prepare_run.stdio = .inherit;

    const prepare_step = b.step("prepare", "Regenerate the checked-in OCaml source manifest");
    prepare_step.dependOn(&prepare_run.step);
}
