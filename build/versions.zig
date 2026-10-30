//! The OCaml releases this build knows about: the `ocaml_*` dependencies in
//! `build.zig.zon`. Adding a release = add the dependency + run `zig build generate`.
//!
//! ```zig
//! const ocaml_versions: Versions = .init(b);
//! const src = ocaml_versions.source(.@"5.5.1") orelse return; // not fetched yet
//! ```
const std = @import("std");
const zon = @import("../build.zig.zon");
const Source = @import("source.zig");

const Versions = @This();

b: *std.Build,

pub fn init(b: *std.Build) Versions {
    return .{ .b = b };
}

/// The source tree of `v`, or `null` if the (lazy) dependency hasn't been fetched
/// yet; zig fetches it and re-runs the build script.
pub fn dependency(self: Versions, v: Version) ?*std.Build.Dependency {
    return self.b.lazyDependency(dependencyName(v), .{});
}

/// The source tree of `v` with its manifest loaded, or `null` if not fetched yet.
pub fn source(self: Versions, v: Version) ?*const Source {
    const dep = self.dependency(v) orelse return null;
    const src = self.b.allocator.create(Source) catch @panic("OOM");
    src.* = .load(self.b, dep, v);
    return src;
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

/// A supported OCaml release, e.g. `.@"5.5.1"`. Declaration order follows `build.zig.zon`.
pub const Version = @Enum(u8, .exhaustive, names: {
    var names: [dep_names.len][]const u8 = undefined;
    for (&names, dep_names) |*n, d| n.* = versionName(d);
    break :names &names;
}, &std.simd.iota(u8, dep_names.len));

pub const all = std.enums.values(Version);

/// Name of the source dependency in `build.zig.zon`, e.g. `ocaml_5_5_1`.
pub fn dependencyName(v: Version) []const u8 {
    return switch (v) {
        inline else => |tag| comptime dep_names[@backingInt(tag)],
    };
}

/// `5_5_1`
pub fn slug(v: Version) []const u8 {
    return dependencyName(v)[dep_prefix.len..];
}

/// Path of the manifest relative to the build root, e.g. `build/manifests/v5_5_1.zon`.
pub fn manifestPath(v: Version) []const u8 {
    return switch (v) {
        inline else => |tag| comptime "build/manifests/v" ++ slug(tag) ++ ".zon",
    };
}

/// Newest release (first `ocaml_*` dependency).
pub const latest: Version = @fromBackingInt(@intCast(0));
