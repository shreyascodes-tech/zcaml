const std = @import("std");
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

const BuildOptions = struct {
    /// The target where the ocaml compiler runs.
    compiler_host: std.Build.ResolvedTarget,
    /// The target where the output of the ocaml compiler runs.
    compiler_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

// probably returns a dir with the final ocaml toolchain i guess
pub fn build(self: *Self, options: BuildOptions) !void {
    _ = .{ self, options };
    // 1. probably boot ocaml c for host?
    // 2. use that to build ocaml for target
    // 3. ???
    // 4. profit?
}

pub fn resolveTarget(ocaml_target: []const u8) std.Build.ResolvedTarget {
    _ = .{ocaml_target};
    @panic("TODO");
}
