const std = @import("std");

const Self = @This();

b: *std.Build,
host_target: std.Build.ResolvedTarget,
ocaml_dep: *std.Build.Dependency,
ocaml_src_root: std.Build.Cache.Path,

pub fn init(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
) Self {
    const ocaml_src_root = ocaml_dep.path("").getPath4(b, null) catch unreachable;
    return .{
        .b = b,
        .host_target = b.graph.host,
        .ocaml_dep = ocaml_dep,
        .ocaml_src_root = ocaml_src_root,
    };
}

pub const BuildOptions = struct {
    compiler_host: std.Build.ResolvedTarget,
    compiler_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(self: *Self, options: BuildOptions) !void {
    _ = .{ self, options };
}
