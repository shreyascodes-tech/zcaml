//! The OCaml releases this build knows about: the `ocaml_*` dependencies in
//! `build.zig.zon`. Adding a release = add the dependency + run `zig build generate`.
//!
//! ```zig
//! const src = Versions.source(b, .@"5.5.1", deps) orelse return; // not fetched yet
//! ```
const std = @import("std");
const zon = @import("../build.zig.zon");
const Source = @import("source.zig");
const Manifest = @import("manifests/manifest.zig");

/// A supported OCaml release, e.g. `.@"5.5.1"`. Declaration order follows `build.zig.zon`.
pub const Version = @Enum(u8, .exhaustive, names: {
    var names: [dep_names.len][]const u8 = undefined;
    for (&names, dep_names) |*n, d| n.* = versionName(d);
    break :names &names;
}, &std.simd.iota(u8, dep_names.len));

pub const all = std.enums.values(Version);

/// Newest release (first `ocaml_*` dependency).
pub const latest: Version = @fromBackingInt(@as(u8, 0));

/// The source tree of `v` with its manifest loaded, or `null` if not fetched yet.
pub fn source(b: *std.Build, v: Version, deps: Source.Deps) ?*const Source {
    const dep = dependency(b, v) orelse return null;
    const src = b.allocator.create(Source) catch @panic("OOM");
    src.* = .{ .b = b, .dep = dep, .manifest = loadManifest(b, v), .deps = deps };
    return src;
}

/// The source tree of `v`, or `null` if the (lazy) dependency hasn't been fetched
/// yet; zig fetches it and re-runs the build script.
pub fn dependency(b: *std.Build, v: Version) ?*std.Build.Dependency {
    return b.lazyDependency(dependencyName(v), .{});
}

/// Path of the manifest relative to the build root, e.g. `build/manifests/v5_5_1.zon`.
pub fn manifestPath(v: Version) []const u8 {
    return switch (v) {
        inline else => |tag| comptime "build/manifests/v" ++ dependencyName(tag)[dep_prefix.len..] ++ ".zon",
    };
}

fn loadManifest(b: *std.Build, v: Version) Manifest {
    const path = manifestPath(v);
    const zon_src = std.Io.Dir.cwd().readFileAllocOptions(
        b.graph.io,
        b.root.joinString(b.allocator, path) catch @panic("OOM"),
        b.allocator,
        .unlimited,
        .of(u8),
        0,
    ) catch |err| std.debug.panic(
        "Failed to read manifest '{s}' for OCaml {t} ({t}). Run `zig build generate`.",
        .{ path, v, err },
    );

    @setEvalBranchQuota(20_000);
    var diag: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = b.graph.arena,
        .diagnostics = &diag,
        .source = zon_src,
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.panic("Failed to parse manifest '{s}': {t}\n{f}\nRun `zig build generate`.", .{ path, err, diag.fmt(path) });
    };

    if (!std.mem.eql(u8, manifest.version.string, @tagName(v))) std.debug.panic(
        "Manifest '{s}' is for OCaml {s}, expected {t}. Run `zig build generate`.",
        .{ path, manifest.version.string, v },
    );
    return manifest;
}

/// Name of the source dependency in `build.zig.zon`, e.g. `ocaml_5_5_1`.
fn dependencyName(v: Version) []const u8 {
    return switch (v) {
        inline else => |tag| comptime dep_names[@backingInt(tag)],
    };
}

const dep_prefix = "ocaml_";

const dep_names = blk: {
    var names: []const []const u8 = &.{};
    for (std.meta.fieldNames(@TypeOf(zon.dependencies))) |f| {
        if (std.mem.startsWith(u8, f, dep_prefix)) names = names ++ .{f};
    }
    if (names.len == 0) @compileError("build.zig.zon has no `ocaml_*` dependencies");
    break :blk names;
};

/// `ocaml_5_5_1` -> `5.5.1`
fn versionName(comptime dep: []const u8) []const u8 {
    comptime {
        var name: [dep.len - dep_prefix.len]u8 = dep[dep_prefix.len..].*;
        std.mem.replaceScalar(u8, &name, '_', '.');
        const final = name;
        return &final;
    }
}
