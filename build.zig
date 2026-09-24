const std = @import("std");
const Context = @import("build/context.zig");

pub fn build(b: *std.Build) !void {
    if (b.option(bool, "__internal_skip_build", "INTERNAL ONLY, DO NOT USE") orelse false) return;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ctx = Context.create(b, b.getInstallStep(), optimize);

    // Bootstrap: always runs on the build machine.
    const boot_ocamlrun = ctx.host().bytecodeRuntime();
    const ocamlc_help = boot_ocamlrun.cmd()
        .inFile(ctx.ocamlRel("boot/ocamlc"))
        .arg("--help")
        .stdout();
    ctx.installFile(.prefix, ocamlc_help, "ocamlc_help");

    // The runtime that ships, built for the target.  When the target matches
    // the host this is the same State as `ctx.host()`, so it's built once.
    const rt = ctx.forTarget(target).bytecodeRuntime();
    ctx.installFile(.bin, rt.exe.getEmittedBin(), "ocamlrun");
    ctx.installFile(.lib, rt.lib.getEmittedBin(), "ocaml/libcamlrun.a");
}

/// Creates a zcaml Context for a build fn that has zcaml as a dependency.
/// Must never be called from the build fn above, or the build script fails.
/// Useful for the eventual public API of zcaml.
pub fn createContext(b: *std.Build, step: *std.Build.Step, optimize: std.builtin.OptimizeMode) *Context {
    const self = b.dependencyFromBuildZig(@This(), .{
        .__internal_skip_build = true,
    });
    return Context.create(self.builder, step, optimize);
}
