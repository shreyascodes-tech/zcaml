const std = @import("std");
const State = @import("build/state.zig");
const version_h = @import("build/config/version_h.zig");
const exec_h = @import("build/config/exec_h.zig");
const m_h = @import("build/config/m_h.zig");
const s_h = @import("build/config/s_h.zig");
const config_common_ml = @import("build/config/config_common_ml.zig");
const config_generated_ml = @import("build/config/config_generated_ml.zig");
const sys_ml = @import("build/config/sys_ml.zig");
const dynlink_config_ml = @import("build/config/dynlink_config_ml.zig");

pub fn build(b: *std.Build) !void {
    if (b.option(bool, "__internal_skip_build", "INTERNAL ONLY, DO NOT USE") orelse false) return;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const state = try createStateInner(b, target, optimize, b.getInstallStep());

    state.installFile(.{ .custom = "runtime/caml" }, version_h.generate(state), "version.h");
    state.installFile(.{ .custom = "runtime/caml" }, exec_h.generate(state), "exec.h");
    state.installFile(.{ .custom = "runtime/caml" }, m_h.generate(state), "m.h");
    state.installFile(.{ .custom = "runtime/caml" }, s_h.generate(state), "s.h");
    state.installFile(.{ .custom = "utils" }, config_common_ml.generate(state), "config.common.ml");
    state.installFile(.{ .custom = "utils" }, config_generated_ml.generate(state), "config.generated.ml");
    state.installFile(.{ .custom = "stdlib" }, sys_ml.generate(state), "sys.ml");
    state.installFile(.{ .custom = "otherlibs/dynlink" }, dynlink_config_ml.generate(state), "dynlink_config.ml");
}

// assumes this is called from a build fn that has zcaml as a dependency
// must never be called from build fn above, or the build script fails
// usefule for eventual public api for zcaml
fn createState(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step) !*State {
    const self = b.dependencyFromBuildZig(@This(), .{
        .__internal_skip_build = true,
    });
    return createStateInner(self.builder, target, optimize, step);
}

/// assumes the passed in b is from executing the current build script.
/// i.e dependencies are resolved relative to the ./build.zig.zon
fn createStateInner(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, step: *std.Build.Step) !*State {
    const ocaml_dep = b.dependency("ocaml", .{});
    const zstd_dep = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    const zstd = zstd_dep.artifact("zstd");
    const state = try b.allocator.create(State);
    state.* = .{
        .b = b,
        .ocaml_dep = ocaml_dep,
        .zstd = zstd,
        .target = target,
        .optimize = optimize,
        .step = step,
    };

    // Keep the target-built archive and its headers in the install graph.  The
    // generated include tree is also what a later Zig/C module gets when it
    // links the artifact, so no generated path is materialized here.
    state.installFile(.lib, zstd.getEmittedBin(), zstd.out_filename);

    const include_install = b.addInstallDirectory(.{
        .source_dir = zstd.getEmittedIncludeTree(),
        .install_dir = .header,
        .install_subdir = "",
    });
    step.dependOn(&include_install.step);

    return state;
}
