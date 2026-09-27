const std = @import("std");

pub fn build(b: *std.Build) !void {
    const ocaml = b.dependency("ocaml", .{});
    _ = ocaml; // autofix

    // example invocation of the example_transform.zig transform
    // const example_transform_exe = b.addExecutable(.{
    //     .name = "example_transform",
    //     .root_module = b.createModule(.{
    //         .target = b.graph.host,
    //         .optimize = .Debug,
    //         .root_source_file = b.path("tools/example_transform.zig"),
    //     }),
    // });
    //
    // const example_transform_run = b.addRunArtifact(example_transform_exe);
    // example_transform_run.addFileArg(ocaml.path("utils/config.common.ml.in"));
    // const example_transform_output = example_transform_run.addOutputFileArg("config.common.ml");
    // b.getInstallStep().dependOn(&b.addInstallFile(example_transform_output, "config.common.ml").step);
}
