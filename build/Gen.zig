//! The `ocaml-gen` host program and the run steps that invoke it.
//!
//! `addDirectoryArg` hashes the *path* of the source tree, not its contents.
//! The path contains the package hash so that is sufficient, but editing files
//! under `zig-pkg/` by hand will not rerun these steps.

const std = @import("std");
const LazyPath = std.Build.LazyPath;

const OCaml = @import("OCaml.zig");

const Gen = @This();

exe: *std.Build.Step.Compile,
src: LazyPath,

pub fn init(b: *std.Build, src: LazyPath) Gen {
    return .{
        .src = src,
        .exe = b.addExecutable(.{
            .name = "ocaml-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("build/gen/main.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                // Shared with the build script; a module cannot import above
                // its root.
                .imports = &.{
                    .{ .name = "Target", .module = b.createModule(.{ .root_source_file = b.path("build/Target.zig") }) },
                    .{ .name = "Sources", .module = b.createModule(.{ .root_source_file = b.path("build/Sources.zig") }) },
                },
            }),
        }),
    };
}

pub const ConfigureOptions = struct {
    host: std.Build.ResolvedTarget,
    target: std.Build.ResolvedTarget,
    toolchain: OCaml.Toolchain,
    layout: Layout = .{ .relative = "../lib/ocaml" },
    /// `-lzstd` resolves because `libzstd.a` is installed alongside the
    /// stdlib, which is always on the linker's search path (see
    /// `Load_path.get_path_list` in `utils/ccomp.ml`).
    zstd_libs: ?[]const u8 = "-lzstd",

    pub const Layout = union(enum) {
        /// `--with-relative-libdir`: bindir-relative path to the stdlib.
        relative: []const u8,
        /// Installation prefix.
        absolute: []const u8,
    };
};

/// A directory of generated headers and `.ml` files to overlay on the tree.
pub fn configure(g: Gen, b: *std.Build, o: ConfigureOptions) LazyPath {
    const run = b.addRunArtifact(g.exe);
    run.addArg("configure");
    run.addArg("--src");
    run.addDirectoryArg(g.src);
    run.addArg("--out");
    const out = run.addOutputDirectoryArg("configure");

    // Fully resolved triples so `ocaml-gen` sees the same libc version the
    // build does (e.g. `HAS_STRLCPY`); the strings in `toolchain` are what
    // users see.
    run.addArgs(&.{ "--target", resolvedTriple(b, o.target) });
    run.addArgs(&.{ "--host", resolvedTriple(b, o.host) });
    run.addArgs(&.{ "--cc", o.toolchain.cc, "--ar", o.toolchain.ar });
    if (o.toolchain.asm_) |a| run.addArgs(&.{ "--asm", a });
    if (o.toolchain.packld) |p| run.addArgs(&.{ "--packld", p });

    switch (o.layout) {
        .relative => |rel| run.addArgs(&.{ "--relative-libdir", rel }),
        .absolute => |prefix| run.addArgs(&.{
            "--bindir", b.fmt("{s}/bin", .{prefix}),
            "--libdir", b.fmt("{s}/lib/ocaml", .{prefix}),
        }),
    }
    if (o.zstd_libs) |libs| run.addArgs(&.{ "--zstd-libs", libs });
    return out;
}

/// `runtime/primitives`, `runtime/prims.c` and `runtime/caml/{opnames,jumptbl}.h`
/// derived from the bytecode runtime's C sources.
pub fn primitives(g: Gen, b: *std.Build, files: []const []const u8) LazyPath {
    const run = b.addRunArtifact(g.exe);
    run.addArg("primitives");
    run.addArg("--src");
    run.addDirectoryArg(g.src);
    run.addArg("--out");
    const out = run.addOutputDirectoryArg("primitives");
    run.addArgs(files);
    return out;
}

pub fn sources(g: Gen, b: *std.Build, ocaml_hash: []const u8) LazyPath {
    const run = b.addRunArtifact(g.exe);
    run.addArg("sources");
    run.addArg("--src");
    run.addDirectoryArg(g.src);
    run.addArgs(&.{ "--ocaml-hash", ocaml_hash });
    run.addArg("--out");
    return run.addOutputFileArg("sources.g.zon");
}

fn resolvedTriple(b: *std.Build, t: std.Build.ResolvedTarget) []const u8 {
    return t.result.zigTriple(b.allocator) catch @panic("OOM");
}
