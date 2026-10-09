const std = @import("std");
const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;
const Compile = Step.Compile;

const Gen = @import("Gen.zig");
const Runtime = @import("Runtime.zig");
const Sources = @import("Sources.zig");

const OCaml = @This();

b: *std.Build,
src: LazyPath,
ocaml_source_hash: []const u8,
/// relative to `build.zig.zon`
sources_manifest_path: []const u8,
gen: Gen,
toolchain: Toolchain,
sources_manifest: ?*const Sources = null,
/// Keyed by resolved zig triple.
runtimes: std.StringArrayHashMapUnmanaged(*Runtime) = .empty,

pub const InitOptions = struct {
    dep: *std.Build.Dependency,
    hash: []const u8,
    sources_manifest_path: []const u8,
    toolchain: Toolchain,
};

pub fn init(b: *std.Build, o: InitOptions) OCaml {
    const src = o.dep.path("");
    return .{
        .b = b,
        .src = src,
        .ocaml_source_hash = o.hash,
        .sources_manifest_path = o.sources_manifest_path,
        .gen = .init(b, src),
        .toolchain = o.toolchain,
    };
}

pub const BuildOptions = struct {
    /// Where the compiler binaries run.
    host: std.Build.ResolvedTarget,
    /// What the compiler produces code for.
    target: std.Build.ResolvedTarget,
    build_machine: ?std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(self: *OCaml, o: BuildOptions) !Artifacts {
    const b = self.b;
    const build_machine = o.build_machine orelse self.b.graph.host;

    const sources = try self.getSourcesManifest();
    const boot_rt = try self.getRuntime(sources, build_machine, o.optimize);
    const host_rt = try self.getRuntime(sources, o.host, o.optimize);
    const target_rt = try self.getRuntime(sources, o.target, o.optimize);

    return .{
        .boot_ocamlrun = boot_rt.ocamlrun(.normal),
        .ocamlrun = host_rt.ocamlrun(.normal),
        .libcamlrun = target_rt.library(.{ .backend = .bytecode }),
        .libasmrun = target_rt.library(.{ .backend = .native }),
        .libcomprmarsh = target_rt.comprmarsh(),
        .libzstd = target_rt.zstd,
        .ld_conf = target_rt.generated.path(b, "runtime/ld.conf"),
        .primitives = target_rt.primitives.path(b, "runtime/primitives"),
        .header_dirs = .{
            target_rt.generated.path(b, "runtime/caml"),
            target_rt.primitives.path(b, "runtime/caml"),
            target_rt.src.path(b, "runtime/caml"),
        },
        .generated = target_rt.generated,
    };
}

pub fn addGenStep(
    self: *OCaml,
    step: *Step,
) void {
    const update = self.b.addUpdateSourceFiles();
    update.addCopyFileToSource(
        self.gen.sources(self.b, self.ocaml_source_hash),
        self.sources_manifest_path,
    );
    step.dependOn(&update.step);
}

pub fn addInstallArtifacts(a: *const Artifacts, b: *std.Build, step: *Step, prefix: []const u8) void {
    const bin = std.Build.InstallDir{ .custom = b.fmt("{s}/bin", .{prefix}) };
    const lib = std.Build.InstallDir{ .custom = b.fmt("{s}/lib/ocaml", .{prefix}) };
    const caml = std.Build.InstallDir{ .custom = b.fmt("{s}/lib/ocaml/caml", .{prefix}) };

    step.dependOn(&b.addInstallArtifact(a.boot_ocamlrun, .{}).step);
    step.dependOn(&b.addInstallArtifact(a.ocamlrun, .{ .dest_dir = .{ .override = bin } }).step);
    inline for (&.{ a.libcamlrun, a.libasmrun, a.libcomprmarsh, a.libzstd }) |c| {
        step.dependOn(&b.addInstallArtifact(c, .{ .dest_dir = .{ .override = lib }, .h_dir = .disabled }).step);
    }
    step.dependOn(&b.addInstallFileWithDir(a.ld_conf, lib, "ld.conf").step);
    step.dependOn(&b.addInstallFileWithDir(a.primitives, lib, "primitives").step);
    for (a.header_dirs) |dir| {
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = dir,
            .install_dir = caml,
            .install_subdir = "",
            .include_extensions = &.{".h"},
        }).step);
    }
}

/// What `ocamlc`/`ocamlopt` invoke on the user's machine; baked into `Config`.
pub const Toolchain = struct {
    cc: []const u8,
    ar: []const u8,
    asm_: ?[]const u8 = null,
    packld: ?[]const u8 = null,
};

pub const Artifacts = struct {
    /// Runs on the build machine; drives `boot/ocamlc`.
    boot_ocamlrun: *Compile,
    /// Runs on `host`.
    ocamlrun: *Compile,
    /// Linked into programs for `target`.
    libcamlrun: *Compile,
    libasmrun: *Compile,
    libcomprmarsh: *Compile,
    libzstd: *Compile,
    ld_conf: LazyPath,
    primitives: LazyPath,
    /// `runtime/caml` header trees for `target`, generated ones first.
    header_dirs: [3]LazyPath,
    /// `ocaml-gen configure` output for `target`.
    generated: LazyPath,

    pub const addInstall = addInstallArtifacts;
};

fn getRuntime(
    self: *OCaml,
    sources: *const Sources,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*Runtime {
    const key = try target.result.zigTriple(self.b.allocator);
    const gop = try self.runtimes.getOrPut(self.b.allocator, key);
    if (!gop.found_existing) {
        const r = try self.b.allocator.create(Runtime);
        r.* = try Runtime.init(self, sources, target, optimize);
        gop.value_ptr.* = r;
    }
    return gop.value_ptr.*;
}

fn getSourcesManifest(self: *OCaml) !*const Sources {
    const b = self.b;
    return self.sources_manifest orelse blk: {
        const sources_file = b.build_root.handle.openFile(b.graph.io, self.sources_manifest_path, .{}) catch return error.SourcesUnavailable;
        const parsed = b.allocator.create(Sources) catch @panic("OOM");
        parsed.* = try Sources.loadFromFile(b.graph.io, b.allocator, sources_file);
        self.sources_manifest = parsed;
        break :blk parsed;
    };
}
