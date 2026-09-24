//! State required for building ocaml.
//! Shared build and configuration utilities live here.

const std = @import("std");

const State = @This();

const LazyPath = std.Build.LazyPath;

b: *std.Build,

ocaml_dep: *std.Build.Dependency,

/// The vendored zstd artifact shared by the configuration and later build
/// stages.  Its emitted binary and include tree remain lazy build paths.
zstd: *std.Build.Step.Compile,

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

pub fn requireLinuxTarget(module: []const u8, target: *const std.Target) void {
    const pointer_bits = target.ptrBitWidth();
    if (target.os.tag != .linux or
        !(target.isGnuLibC() or target.isMuslLibC()) or
        target.ofmt != .elf or
        (pointer_bits != 32 and pointer_bits != 64))
    {
        std.debug.panic(
            "{s}: unsupported target {s}-{s}-{s} (object format {s}, {d}-bit pointers); expected Linux GNU/musl ELF with 32- or 64-bit pointers",
            .{
                module,
                @tagName(target.cpu.arch),
                @tagName(target.os.tag),
                @tagName(target.abi),
                @tagName(target.ofmt),
                pointer_bits,
            },
        );
    }
}
