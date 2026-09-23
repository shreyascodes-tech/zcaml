const std = @import("std");
const State = @import("build/state.zig");

pub fn build(b: *std.Build) !void {
    if (b.option(bool, "__internal_skip_build", "INTERNAL ONLY, DO NOT USE") orelse false) return;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const state = try createStateInner(b, target, optimize, b.getInstallStep());
    _ = state;
}

// assumes this is called from a build fn that has zcaml as a dependency
// must never be called from build fn above, or the build script fails
// usefule for eventual public api for zcaml
fn createState(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step) !State {
    const self = b.dependencyFromBuildZig(@This(), .{
        .__internal_skip_build = true,
    });
    return createStateInner(self.builder, target, optimize, step);
}

/// assumes the passed in b is from executing the current build script.
/// i.e dependencies are resolved relative to the ./build.zig.zon
fn createStateInner(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step) !*State {
    const ocaml_dep = b.dependency("ocaml", .{});
    const state = try b.allocator.create(State);
    state.* = .{
        .b = b,
        .ocaml_dep = ocaml_dep,
        .target = target,
        .optimize = optimize,
        .step = step,
    };
    return state;
}
