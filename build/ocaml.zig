const std = @import("std");
const target_config = @import("target_config.zig");
const source_info = @import("source_info.zig");
const runtime = @import("runtime.zig");

pub const TargetConfig = target_config.TargetConfig;
pub const SourceInfo = source_info.SourceInfo;
pub const RuntimeArtifacts = runtime.RuntimeArtifacts;

const Self = @This();

b: *std.Build,
dep: *std.Build.Dependency,
src_info: SourceInfo,

pub fn init(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
) *Self {
    const self = b.allocator.create(Self) catch @panic("OOM");
    self.* = .{
        .b = b,
        .dep = ocaml_dep,
        .src_info = SourceInfo.load(b, ocaml_dep),
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

pub const InstallOptions = struct {
    /// Optional prefix relative to the install root (e.g. "x86_64-linux-gnu").
    /// When null, installs into standard `bin/` and `lib/ocaml/` under the install prefix.
    prefix: ?[]const u8 = null,
};

pub const Toolchain = struct {
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    host_cfg: TargetConfig,
    target_cfg: TargetConfig,
    target_rt: RuntimeArtifacts,

    pub fn addInstall(self: Toolchain, step: *std.Build.Step, options: InstallOptions) void {
        const b = self.b;

        const bin_dir: std.Build.InstallDir = if (options.prefix) |p|
            .{ .custom = b.fmt("{s}/bin", .{p}) }
        else
            .bin;

        const ocaml_lib_dir: std.Build.InstallDir = if (options.prefix) |p|
            .{ .custom = b.fmt("{s}/lib/ocaml", .{p}) }
        else
            .{ .custom = "lib/ocaml" };

        // Binaries -> <prefix>/bin/
        step.dependOn(&b.addInstallArtifact(self.target_rt.ocamlrun, .{
            .dest_dir = .{ .override = bin_dir },
            .pdb_dir = .disabled,
        }).step);
        step.dependOn(&b.addInstallArtifact(self.target_rt.ocamlyacc, .{
            .dest_dir = .{ .override = bin_dir },
            .pdb_dir = .disabled,
        }).step);

        // Runtime static libraries -> <prefix>/lib/ocaml/
        step.dependOn(&b.addInstallArtifact(self.target_rt.libcamlrun, .{
            .dest_dir = .{ .override = ocaml_lib_dir },
        }).step);
        if (self.target_rt.libasmrun) |asmrun| {
            step.dependOn(&b.addInstallArtifact(asmrun, .{
                .dest_dir = .{ .override = ocaml_lib_dir },
            }).step);
        }
        step.dependOn(&b.addInstallArtifact(self.target_rt.libcomprmarsh, .{
            .dest_dir = .{ .override = ocaml_lib_dir },
        }).step);

        // Primitives & runtime C headers -> <prefix>/lib/ocaml/
        step.dependOn(&b.addInstallFileWithDir(
            self.target_rt.primitives,
            ocaml_lib_dir,
            "primitives",
        ).step);
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = self.ocaml_dep.path("runtime/caml"),
            .install_dir = ocaml_lib_dir,
            .install_subdir = "caml",
            .exclude_extensions = &.{ ".in", "dune" },
        }).step);
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = self.target_rt.headers_dir.path(b, "caml"),
            .install_dir = ocaml_lib_dir,
            .install_subdir = "caml",
        }).step);
    }
};

pub fn build(self: *Self, options: BuildOptions) !Toolchain {
    const b = self.b;

    const host_cfg = TargetConfig.fromTarget(b, options.compiler_host, self.src_info.version);
    const target_cfg = TargetConfig.fromTarget(b, options.compiler_target, self.src_info.version);

    const target_rt = try runtime.buildRuntime(b, self.dep, .{
        .src_info = self.src_info,
        .target_cfg = target_cfg,
        .optimize = options.optimize,
    });

    return .{
        .b = b,
        .ocaml_dep = self.dep,
        .host_cfg = host_cfg,
        .target_cfg = target_cfg,
        .target_rt = target_rt,
    };
}

pub fn resolveTarget(b: *std.Build, ocaml_target: []const u8) std.Build.ResolvedTarget {
    return target_config.resolveTarget(b, ocaml_target);
}
