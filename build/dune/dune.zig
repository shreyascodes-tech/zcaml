//! Dune, bootstrapped (`boot/bootstrap.ml`, as dune's own releases are) for any
//! target with a zcaml toolchain running on the build machine.
//!
//! ```zig
//! const dune: Dune = .init(b, b.dependency("dune", .{}), macos_sdk);
//! const exe = dune.bootstrap(native_toolchain.directory(), aarch64_toolchain.directory(), aarch64_linux);
//! ```
const std = @import("std");
const LazyPath = std.Build.LazyPath;

const Dune = @This();

b: *std.Build,
src: LazyPath,
/// For macOS targets, which link Apple's frameworks (`Ocaml.MacosSdk`).
macos_sdk: ?LazyPath,

pub fn init(b: *std.Build, dep: *std.Build.Dependency, macos_sdk: ?LazyPath) Dune {
    return .{ .b = b, .src = dep.path(""), .macos_sdk = macos_sdk };
}

/// `dune(.exe)` for `target`, with `toolchain`, a toolchain installation for it
/// running here, like `host_toolchain`: the native one, which runs the bootstrap.
/// Its entry point is `main.zig`'s.
pub fn bootstrap(self: Dune, host_toolchain: LazyPath, toolchain: LazyPath, target: std.Build.ResolvedTarget) LazyPath {
    const b = self.b;
    const os = target.result.os.tag;
    const run = b.addRunArtifact(toolExe(b));
    run.setName("bootstrap dune");
    setEnv(b, run);
    run.addDirectoryArg(self.src);
    run.addDirectoryArg(host_toolchain);
    run.addDirectoryArg(toolchain);
    run.addArg(@tagName(os));
    run.addFileArg(mainObject(b, target).getEmittedBin());
    const out = run.addOutputFileArg(if (os == .windows) "dune.exe" else "dune");
    if (os == .macos) run.addDirectoryArg(self.macos_sdk orelse @panic("dune for macOS needs the macOS SDK"));
    return out;
}

/// The bootstrap's Zig programs, for the build machine: `zig build check`.
pub fn addCheck(b: *std.Build, step: *std.Build.Step) void {
    step.dependOn(&mainObject(b, b.graph.host).step);
    step.dependOn(&toolExe(b).step);
}

fn mainObject(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const obj = b.addObject(.{
        .name = "dune-main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/dune/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            // Linked by the toolchain's `zig cc`, without Zig's runtime libraries.
            .stack_check = false,
            .stack_protector = false,
            .strip = true,
        }),
    });
    obj.bundle_compiler_rt = true;
    return obj;
}

fn toolExe(b: *std.Build) *std.Build.Step.Compile {
    const S = struct {
        var exe: ?*std.Build.Step.Compile = null;
    };
    if (S.exe == null) S.exe = b.addExecutable(.{
        .name = "dune-bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/dune/tool.zig"),
            .target = b.graph.host,
        }),
    });
    return S.exe.?;
}

/// Only what the toolchains and `zig cc` need, so that unrelated variables
/// (`OCAMLPATH`, opam's, ...) neither leak in nor rerun the step.
fn setEnv(b: *std.Build, run: *std.Build.Step.Run) void {
    const parent = &b.graph.environ_map;
    run.clearEnvironment();
    const env = run.getEnvMap();
    for ([_][]const u8{
        "HOME",        "XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LIB_DIR", "TMPDIR",
        "USERPROFILE", "LOCALAPPDATA",   "APPDATA",              "TEMP",        "TMP",
        "SystemRoot",  "windir",         "ComSpec",              "PATHEXT",
    }) |key| {
        if (parent.get(key)) |value| env.put(key, value) catch @panic("OOM");
    }
    // The Zig of this build, for `zig cc`.
    env.put("PATH", b.fmt("{s}{s}{s}", .{
        std.fs.path.dirname(b.graph.zig_exe).?,
        if (b.graph.host.result.os.tag == .windows) ";" else ":",
        parent.get("PATH") orelse "",
    })) catch @panic("OOM");
}
