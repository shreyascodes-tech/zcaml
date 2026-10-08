//! Build-graph root for the OCaml distribution. Registers no top-level steps
//! and installs nothing on its own: callers pass in the step work should hang
//! off, and get back what was produced.

const std = @import("std");
const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;
const Compile = Step.Compile;

const Gen = @import("Gen.zig");
const Runtime = @import("Runtime.zig");
const Sources = @import("Sources.zig");

const OCaml = @This();

const sources_zon = "build/gen/sources.g.zon";

/// What `ocamlc`/`ocamlopt` invoke on the user's machine; baked into `Config`.
pub const Toolchain = struct {
    cc: []const u8,
    ar: []const u8,
    asm_: ?[]const u8 = null,
    packld: ?[]const u8 = null,
};

b: *std.Build,
src: LazyPath,
/// The `ocaml` dependency's hash from `build.zig.zon`; identifies which tree
/// `sources.g.zon` was generated from.
hash: []const u8,
gen: Gen,
toolchain: Toolchain,
sources_cache: ?*const Sources = null,
/// Keyed by resolved zig triple.
runtimes: std.StringArrayHashMapUnmanaged(*Runtime) = .empty,

pub const InitOptions = struct {
    dep: *std.Build.Dependency,
    hash: []const u8,
    toolchain: Toolchain,
};

pub fn init(b: *std.Build, o: InitOptions) OCaml {
    const src = o.dep.path("");
    return .{
        .b = b,
        .src = src,
        .hash = o.hash,
        .gen = .init(b, src),
        .toolchain = o.toolchain,
    };
}

/// Regenerates `sources.g.zon` from the OCaml tree. Does not itself need a
/// valid one.
pub fn addGenStep(self: *OCaml, step: *Step) void {
    const update = self.b.addUpdateSourceFiles();
    update.addCopyFileToSource(self.gen.sources(self.b, self.hash), sources_zon);
    step.dependOn(&update.step);
}

pub const BuildOptions = struct {
    /// Where the compiler binaries run.
    host: std.Build.ResolvedTarget,
    /// What the compiler produces code for.
    target: std.Build.ResolvedTarget,
    /// Where the bytecode interpreter that runs `boot/ocamlc` during the
    /// build runs. Normally the build machine; overridable so a cross-built
    /// `ocamlrun` can be tested under an emulator.
    build_machine: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

    /// Installs under `<prefix>/{bin,lib/ocaml}`. `bin/` runs on the host,
    /// `lib/ocaml/` is linked into programs for the target.
    pub fn addInstall(a: Artifacts, step: *Step, prefix: []const u8) void {
        const b = step.owner;
        const bin: std.Build.InstallDir = .{ .custom = b.fmt("{s}/bin", .{prefix}) };
        const lib: std.Build.InstallDir = .{ .custom = b.fmt("{s}/lib/ocaml", .{prefix}) };
        const caml: std.Build.InstallDir = .{ .custom = b.fmt("{s}/lib/ocaml/caml", .{prefix}) };

        step.dependOn(&b.addInstallArtifact(a.boot_ocamlrun, .{}).step);
        step.dependOn(&b.addInstallArtifact(a.ocamlrun, .{ .dest_dir = .{ .override = bin } }).step);
        for ([_]*Compile{ a.libcamlrun, a.libasmrun, a.libcomprmarsh, a.libzstd }) |c| {
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
};

pub const BuildError = error{
    /// A `Fail` step with the reason has been attached to `step`; return
    /// normally and let the build report it.
    SourcesUnavailable,
    OutOfMemory,
    UnsupportedTarget,
};

pub fn build(self: *OCaml, step: *Step, o: BuildOptions) BuildError!Artifacts {
    const srcs = try self.sources(step);

    const boot_rt = try self.runtime(srcs, o.build_machine, o.optimize);
    const host_rt = try self.runtime(srcs, o.host, o.optimize);
    const target_rt = try self.runtime(srcs, o.target, o.optimize);

    const b = self.b;
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

/// `arch-os-abi` with no version ranges. A resolved target's `zigTriple`
/// includes the detected kernel and glibc versions, and a query's can be
/// `native`; neither belongs in `config.ml` or an install path.
pub fn plainTriple(b: *std.Build, t: std.Build.ResolvedTarget) []const u8 {
    const r = t.result;
    return b.fmt("{t}-{t}-{t}", .{ r.cpu.arch, r.os.tag, r.abi });
}

fn runtime(
    self: *OCaml,
    srcs: *const Sources,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) error{ OutOfMemory, UnsupportedTarget }!*Runtime {
    const key = try target.result.zigTriple(self.b.allocator);
    const gop = try self.runtimes.getOrPut(self.b.allocator, key);
    if (!gop.found_existing) {
        const r = try self.b.allocator.create(Runtime);
        r.* = try Runtime.init(self, srcs, target, optimize);
        gop.value_ptr.* = r;
    }
    return gop.value_ptr.*;
}

fn sources(self: *OCaml, step: *Step) error{SourcesUnavailable}!*const Sources {
    if (self.sources_cache) |s| return s;
    const b = self.b;
    const s = self.loadSources() catch |err| {
        step.dependOn(&b.addFail(switch (err) {
            error.FileNotFound => b.fmt("{s} is missing; run `zig build gen`", .{sources_zon}),
            error.StaleSources => b.fmt("{s} was generated from a different OCaml than build.zig.zon has; run `zig build gen`", .{sources_zon}),
            else => b.fmt("{s}: {t}", .{ sources_zon, err }),
        }).step);
        return error.SourcesUnavailable;
    };
    self.sources_cache = s;
    return s;
}

fn loadSources(self: *OCaml) !*const Sources {
    const b = self.b;
    const text = try b.build_root.handle.readFileAllocOptions(
        b.graph.io,
        sources_zon,
        b.allocator,
        .unlimited,
        .@"1",
        0,
    );
    var diag: std.zon.parse.Diagnostics = .{};
    const s = try b.allocator.create(Sources);
    s.* = Sources.parse(b.allocator, text, &diag) catch |err| switch (err) {
        error.ParseZon => {
            std.log.err("{s}: {f}", .{ sources_zon, diag });
            return err;
        },
        else => |e| return e,
    };
    if (!std.mem.eql(u8, s.ocaml_hash, self.hash)) return error.StaleSources;
    return s;
}
