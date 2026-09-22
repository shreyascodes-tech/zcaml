const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ocaml_dep = b.dependency("ocaml", .{});
    const ocaml_src_path = ocaml_dep.path(".");

    // probably produces a dir with the generated config files?
    // and returns a write file object idk
    _ = try configureMyCaml(.{
        .b = b,
        .ocaml_dep = ocaml_dep,
        .root = ocaml_src_path,
        .target = target,
        .optimize = optimize,
        .step = b.getInstallStep(),
    });
}

const State = struct {
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step: *std.Build.Step,
};

fn configureMyCaml(state: State) !void {
    _ = state;
}
