const std = @import("std");
const target_config = @import("target_config.zig");
const runtime = @import("runtime.zig");

pub const TargetConfig = target_config.TargetConfig;
pub const RuntimeArtifacts = runtime.RuntimeArtifacts;

const Self = @This();

b: *std.Build,
dep: *std.Build.Dependency,

pub fn init(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
) *Self {
    const self = b.allocator.create(Self) catch @panic("OOM");
    self.* = .{
        .b = b,
        .dep = ocaml_dep,
    };
    return self;
}

pub const BuildOptions = struct {
    /// The target where the ocaml compiler runs.
    compiler_host: std.Build.ResolvedTarget,
    /// The target where the output of the ocaml compiler runs.
    compiler_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(self: *Self, options: BuildOptions) !RuntimeArtifacts {
    const b = self.b;

    const host_cfg = TargetConfig.fromTarget(b, options.compiler_host);
    const target_cfg = TargetConfig.fromTarget(b, options.compiler_target);

    // Build runtime & ocamlyacc for compiler_target (and compiler_host if same)
    const target_rt = try runtime.buildRuntime(b, self.dep, .{
        .target_cfg = target_cfg,
        .optimize = options.optimize,
    });

    // Install Milestone 1 artifacts so they can be verified in zig-out/
    b.installArtifact(target_rt.ocamlrun);
    b.installArtifact(target_rt.ocamlyacc);
    b.installArtifact(target_rt.libcamlrun);
    if (target_rt.libasmrun) |asmrun| {
        b.installArtifact(asmrun);
    }
    b.installArtifact(target_rt.libcomprmarsh);
    b.getInstallStep().dependOn(
        &b.addInstallFileWithDir(target_rt.primitives, .lib, "ocaml/primitives").step,
    );

    _ = host_cfg;
    return target_rt;
}

pub fn resolveTarget(b: *std.Build, ocaml_target: []const u8) std.Build.ResolvedTarget {
    return target_config.resolveTarget(b, ocaml_target);
}
