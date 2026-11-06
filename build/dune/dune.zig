//! Dune, bootstrapped (`boot/bootstrap.ml`, as dune's own releases are) for any
//! target with a zcaml toolchain running on the build machine.
//!
//! ```zig
//! const dune: Dune = .init(b, b.dependency("dune", .{}));
//! const exe = dune.bootstrap(native_toolchain.directory(), aarch64_toolchain.directory(), false);
//! ```
const std = @import("std");
const LazyPath = std.Build.LazyPath;

const Dune = @This();

b: *std.Build,
src: LazyPath,

pub fn init(b: *std.Build, dep: *std.Build.Dependency) Dune {
    return .{ .b = b, .src = dep.path("") };
}

/// `dune(.exe)` for the target of `toolchain`, a toolchain installation running
/// here, like `host_toolchain`: the native one, which runs the bootstrap.
pub fn bootstrap(self: Dune, host_toolchain: LazyPath, toolchain: LazyPath, target_is_windows: bool) LazyPath {
    const b = self.b;
    const run = b.addRunArtifact(toolExe(b));
    run.setName("bootstrap dune");
    setEnv(b, run);
    run.addDirectoryArg(self.src);
    run.addDirectoryArg(host_toolchain);
    run.addDirectoryArg(toolchain);
    return run.addOutputFileArg(if (target_is_windows) "dune.exe" else "dune");
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
