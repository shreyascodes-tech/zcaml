const std = @import("std");

const Target = @import("Target.zig");
const runtime = @import("runtime.zig");

const Self = @This();

b: *std.Build,
host_target: std.Build.ResolvedTarget,
ocaml_dep: *std.Build.Dependency,
ocaml_src_root: std.Build.Cache.Path,
gen_exe: *std.Build.Step.Compile,
/// Used for compressed marshalling of `.cmi`/`.cmt` files. Built per target,
/// so it is resolved lazily by `zstd`.
zstd_builds: std.StringArrayHashMapUnmanaged(*std.Build.Step.Compile),

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
        .gen_exe = b.addExecutable(.{
            .name = "ocaml-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("build/gen.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        }),
        .zstd_builds = .empty,
    };
}

/// zstd for `target`. One `b.dependency` call per target, memoised because
/// asking twice would build it twice.
fn zstd(self: *Self, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const b = self.b;
    const key = zigTriple(b, target);
    const entry = self.zstd_builds.getOrPut(b.allocator, key) catch @panic("OOM");
    if (!entry.found_existing) {
        entry.value_ptr.* = b.dependency("zstd", .{
            .target = target,
            .optimize = .ReleaseFast,
            // Only the streaming compress/decompress API is reachable from
            // `runtime/zstd.c`.
            .dictbuilder = false,
            .deprecated = false,
            .@"legacy-support" = @as(usize, 0),
        }).artifact("zstd");
    }
    return entry.value_ptr.*;
}

pub const BuildOptions = struct {
    compiler_host: std.Build.ResolvedTarget,
    compiler_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Where the bytecode interpreter that runs `boot/ocamlc` should run.
    /// Defaults to the build machine; overridable so that a cross-built
    /// `ocamlrun` can be tested under an emulator.
    build_machine: ?std.Build.ResolvedTarget = null,
};

pub fn build(self: *Self, options: BuildOptions) !void {
    const b = self.b;

    const cfg = self.configure(.{
        .host = options.compiler_host,
        .target = options.compiler_target,
    });
    const prims = self.primitives(options.compiler_target);
    for ([_]std.Build.LazyPath{ cfg, prims }) |dir| {
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = dir,
            .install_dir = .prefix,
            .install_subdir = "generated",
        }).step);
    }

    // The interpreter that runs `boot/ocamlc`, so it is built for the build
    // machine rather than for the compiler's host or target.
    const build_machine = options.build_machine orelse b.graph.host;
    b.installArtifact(runtime.ocamlrun(b, self.runtimeOptions(.{
        .target = build_machine,
        .optimize = options.optimize,
    }), .normal));
}

pub const RuntimeTarget = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Generates the headers a runtime for `t.target` needs and bundles them with
/// the source tree.
pub fn runtimeOptions(self: *Self, t: RuntimeTarget) runtime.Options {
    const info = self.b.allocator.create(Target) catch @panic("OOM");
    info.* = Target.resolve(t.target.result) catch
        std.debug.panic("unsupported target '{s}'", .{zigTriple(self.b, t.target)});
    return .{
        .target = t.target,
        .info = info,
        .optimize = t.optimize,
        .generated = self.configure(.{ .host = t.target, .target = t.target }),
        .primitives = self.primitives(t.target),
        .src = self.ocaml_dep.path(""),
        .zstd = self.zstd(t.target),
    };
}

pub const ConfigureOptions = struct {
    host: std.Build.ResolvedTarget,
    target: std.Build.ResolvedTarget,
    /// `null` selects a relocatable layout (`--with-relative-libdir`).
    prefix: ?[]const u8 = null,
};

/// Runs `ocaml-gen configure`, yielding a directory of generated headers and
/// `.ml` files to be overlaid on the OCaml source tree.
pub fn configure(self: *Self, options: ConfigureOptions) std.Build.LazyPath {
    const b = self.b;
    const run = b.addRunArtifact(self.gen_exe);
    run.addArgs(&.{"configure"});

    run.addArg("--src");
    run.addDirectoryArg(self.ocaml_dep.path(""));

    run.addArg("--out");
    const out = run.addOutputDirectoryArg("configure");

    const target_triple = zigTriple(b, options.target);
    run.addArgs(&.{ "--target", target_triple });
    run.addArgs(&.{ "--host", zigTriple(b, options.host) });
    run.addArgs(&.{ "--cc", b.fmt("{s} cc -target {s}", .{ b.graph.zig_exe, target_triple }) });
    run.addArgs(&.{ "--ar", b.fmt("{s} ar", .{b.graph.zig_exe}) });

    if (options.prefix) |prefix| {
        run.addArgs(&.{ "--bindir", b.fmt("{s}/bin", .{prefix}) });
        run.addArgs(&.{ "--libdir", b.fmt("{s}/lib/ocaml", .{prefix}) });
    } else {
        run.addArgs(&.{ "--relative-libdir", "../lib/ocaml" });
    }

    // `-lzstd` resolves because `libzstd.a` is installed alongside the
    // standard library, which is always on the linker's search path (see
    // `Load_path.get_path_list` in `utils/ccomp.ml`).
    run.addArgs(&.{ "--zstd-libs", "-lzstd" });

    return out;
}

/// Runs `ocaml-gen primitives`, yielding `runtime/primitives`,
/// `runtime/prims.c` and the two headers derived from `instruct.h`.
pub fn primitives(self: *Self, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const b = self.b;
    const run = b.addRunArtifact(self.gen_exe);
    run.addArgs(&.{"primitives"});

    run.addArg("--src");
    run.addDirectoryArg(self.ocaml_dep.path(""));

    run.addArg("--out");
    const out = run.addOutputDirectoryArg("primitives");

    if (target.result.os.tag == .windows) run.addArg("--win32");
    return out;
}

fn zigTriple(b: *std.Build, t: std.Build.ResolvedTarget) []const u8 {
    return t.result.zigTriple(b.allocator) catch @panic("OOM");
}
