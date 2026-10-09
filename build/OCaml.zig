const std = @import("std");
const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;
const Compile = Step.Compile;

const Gen = @import("Gen.zig");
const Runtime = @import("Runtime.zig");
const Sources = @import("Sources.zig");
const Toolchain = @import("Toolchain.zig");
const Bootstrap = @import("Bootstrap.zig");

const OCaml = @This();

b: *std.Build,
src: LazyPath,
ocaml_source_hash: []const u8,
/// relative to `build.zig.zon`
sources_manifest_path: []const u8,
gen: Gen,
toolchain: Toolchain,
sources_manifest: ?*const Sources = null,
bootstrap: ?Bootstrap = null,
/// Keyed by resolved target (including CPU settings) and optimization mode.
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
    const build_machine = o.build_machine orelse self.b.graph.host;

    const sources = try self.getSourcesManifest();

    if (self.bootstrap == null) {
        const rt = try self.getRuntime(sources, build_machine, o.optimize);
        self.bootstrap = try Bootstrap.build(self.b, .{
            .src = self.src,
            .gen = self.gen,
            .sources = sources,
            .runtime = rt,
        });
    }

    const host_rt = try self.getRuntime(sources, o.host, o.optimize);
    const target_rt = try self.getRuntime(sources, o.target, o.optimize);

    return .{
        .host_ocamlrun = host_rt.ocamlrun(.normal),
        .runtime = target_rt.artifacts(),
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

pub const Artifacts = struct {
    host_ocamlrun: *Compile,
    runtime: Runtime.Artifacts,

    pub fn addInstall(a: Artifacts, b: *std.Build, step: *Step, prefix: []const u8) void {
        const bin = std.Build.InstallDir{ .custom = b.fmt("{s}/bin", .{prefix}) };
        step.dependOn(&b.addInstallArtifact(a.host_ocamlrun, .{ .dest_dir = .{ .override = bin } }).step);
        a.runtime.addInstall(b, step, prefix);
    }
};

fn getRuntime(
    self: *OCaml,
    sources: *const Sources,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*Runtime {
    const gpa = self.b.allocator;

    const key = try runtimeKey(gpa, target.result, optimize);
    errdefer gpa.free(key);

    if (self.runtimes.get(key)) |r| {
        gpa.free(key);
        return r;
    }

    const r = try gpa.create(Runtime);
    errdefer gpa.destroy(r);
    r.* = try Runtime.init(self.b, .{
        .src = self.src,
        .gen = self.gen,
        .sources = sources,
        .target = target,
        .optimize = optimize,
        .toolchain = self.toolchain,
    });

    try self.runtimes.put(gpa, key, r);
    return r;
}

fn runtimeKey(gpa: std.mem.Allocator, target: std.Target, optimize: std.builtin.OptimizeMode) ![]const u8 {
    const triple = try target.zigTriple(gpa);
    defer gpa.free(triple);
    return std.fmt.allocPrint(gpa, "{s}:{s}:{any}:{t}:{t}:{s}", .{
        triple,
        target.cpu.model.name,
        target.cpu.features.ints,
        target.ofmt,
        optimize,
        target.dynamic_linker.get() orelse "",
    });
}

fn getSourcesManifest(self: *OCaml) !*const Sources {
    const b = self.b;
    return self.sources_manifest orelse blk: {
        const sources_file = b.build_root.handle.openFile(b.graph.io, self.sources_manifest_path, .{}) catch return error.SourcesUnavailable;
        defer sources_file.close(b.graph.io);
        const parsed = b.allocator.create(Sources) catch @panic("OOM");
        parsed.* = try Sources.loadFromFile(b.graph.io, b.allocator, sources_file);
        if (!std.mem.eql(u8, parsed.ocaml_hash, self.ocaml_source_hash)) return error.SourcesHashMismatch;
        self.sources_manifest = parsed;
        break :blk parsed;
    };
}
