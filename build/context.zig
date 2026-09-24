//! Target-independent build context.  There is one per builder; it is
//! shared by every target being built.
//!
//! Owns what all targets share: the OCaml source package, the host build tools
//! from ./tools, the install step, the optimize mode, and a cache of per-target
//! `State`s.  Building N targets means one Context, N target States, and one
//! host State that the bootstrap uses.  Asking for the same target twice
//! returns the same State.

const std = @import("std");
const tools = @import("tools.zig");
const State = @import("state.zig");

const Context = @This();
const LazyPath = std.Build.LazyPath;

/// The zcaml builder.  `b.path(...)` resolves relative to zcaml's build root.
b: *std.Build,

ocaml_dep: *std.Build.Dependency,

/// the step that triggered this ocaml build
/// can be used to attach file installations etc to it
step: *std.Build.Step,

/// Optimize mode for everything built by this context, host and targets alike.
optimize: std.builtin.OptimizeMode,

/// Compiled build tools, keyed by source path relative to zcaml's root.
zig_tools: std.StringHashMapUnmanaged(*tools.ZigTool) = .empty,

/// Per-target states, keyed by `stateKey`.
states: std.StringArrayHashMapUnmanaged(*State) = .empty,

pub fn create(b: *std.Build, step: *std.Build.Step, optimize: std.builtin.OptimizeMode) *Context {
    const self = b.allocator.create(Context) catch @panic("OOM");
    self.* = .{
        .b = b,
        .ocaml_dep = b.dependency("ocaml", .{}),
        .step = step,
        .optimize = optimize,
    };
    return self;
}

/// Returns the (cached) State for building OCaml artifacts for `target`.
pub fn forTarget(self: *Context, target: std.Build.ResolvedTarget) *State {
    const key = stateKey(self.b, &target.result);
    const gop = self.states.getOrPut(self.b.allocator, key) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = State.create(self, target);
    return gop.value_ptr.*;
}

/// The State for the machine running the build.  Anything that is executed
/// during the build (bootstrap ocamlrun, boot compilers) comes from here.
pub fn host(self: *Context) *State {
    return self.forTarget(self.b.graph.host);
}

/// Returns the host executable for a Zig program at `src` (relative to
/// zcaml's build root, e.g. "tools/gen-prims.zig"), compiling it on first use.
pub fn tool(self: *Context, src: []const u8) *const tools.ZigTool {
    const gop = self.zig_tools.getOrPut(self.b.allocator, src) catch @panic("OOM");
    if (!gop.found_existing) {
        const t = self.b.allocator.create(tools.ZigTool) catch @panic("OOM");
        const name = self.b.fmt("zcaml-{s}", .{std.fs.path.stem(src)});
        t.* = .init(self.b, name, self.b.path(src));
        gop.value_ptr.* = t;
    }
    return gop.value_ptr.*;
}

pub fn ocamlRel(self: *const Context, sub: []const u8) LazyPath {
    return self.ocaml_dep.path(sub);
}

/// Adds a file to the install step.
/// `dest_rel_path` is relative to the install prefix path.
/// Example:
/// ```zig
/// ctx.installFile(.prefix, file, "hi"); // installs file to zig-out/hi
/// ctx.installFile(.lib, file, "hi"); // installs file to zig-out/lib/hi
/// ctx.installFile(.bin, file, "hi"); // installs file to zig-out/bin/hi
/// ctx.installFile(.header, file, "hi"); // installs file to zig-out/include/hi
/// ctx.installFile(.{ .custom = "foo" }, file, "hi"); // installs file to zig-out/foo/hi
/// ```
pub fn installFile(
    self: *const Context,
    dir: std.Build.InstallDir,
    src: LazyPath,
    dest_rel_path: []const u8,
) void {
    self.step.dependOn(
        &self.b.addInstallFileWithDir(src, dir, dest_rel_path).step,
    );
}

/// Identity of a State: everything about the target that affects generated code.
/// Built from the resolved target (not the query), so `-Dtarget=native` and
/// the build host map to the same State.
fn stateKey(b: *std.Build, t: *const std.Target) []const u8 {
    const triple = t.zigTriple(b.allocator) catch @panic("OOM");
    const features = std.hash.Wyhash.hash(0, t.cpu.features.asBytes());
    return b.fmt("{s}:{s}:{x}:{s}", .{
        triple,
        t.cpu.model.name,
        features,
        @tagName(t.ofmt),
    });
}
