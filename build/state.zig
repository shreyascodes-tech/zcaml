//! State required for building ocaml.
//! Only util methods. No build logic happens here.

const std = @import("std");

const State = @This();

const LazyPath = std.Build.LazyPath;

b: *std.Build,

ocaml_dep: *std.Build.Dependency,

/// the output target of exes final ocaml will produce
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
/// the step that triggerd this ocaml build
/// can be used to attach file installations etc to it
step: *std.Build.Step,

pub fn ocamlRel(self: *const State, sub: []const u8) LazyPath {
    return self.ocaml_dep.path(sub);
}

/// Adds a file to the install step.
/// `dest_rel_path` is relative to the install prefix path.
/// Example:
/// ```zig
/// state.installFile(.prefix, file, "hi"); // installs file to zig-out/hi
/// state.installFile(.lib, file, "hi"); // installs file to zig-out/lib/hi
/// state.installFile(.bin, file, "hi"); // installs file to zig-out/bin/hi
/// state.installFile(.header, file, "hi"); // installs file to zig-out/include/hi
/// state.installFile(.{ .custom = "foo" }, file, "hi"); // installs file to zig-out/foo/hi
/// ```
pub fn installFile(
    self: *const State,
    dir: std.Build.InstallDir,
    src: LazyPath,
    dest_rel_path: []const u8,
) void {
    self.step.dependOn(
        &self.b.addInstallFileWithDir(src, dir, dest_rel_path).step,
    );
}

}
