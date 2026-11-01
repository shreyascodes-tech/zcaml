//! Build an OCaml toolchain from source with Zig.
//!
//! ```zig
//! const ocaml_versions: Ocaml.Versions = .init(b);
//! const src = ocaml_versions.source(.@"5.5.1") orelse return;
//! const toolchain = Ocaml.build(src, .{ .host = host, .target = target, .optimize = optimize });
//! toolchain.addInstall(b.getInstallStep(), "5.5.1/host-x86_64-linux-gnu/target-x86_64-linux-gnu");
//! ```
//!
//! The result is a self-contained, relocatable install tree (`toolchain.layout`):
//!
//! ```text
//! bin/        ocamlc ocamlopt ocaml ocamlrun ... (+ ocamlrun-target when cross compiling)
//! lib/ocaml/  stdlib, runtime libs & headers, compiler-libs, otherlibs, stublibs/
//! ```
const std = @import("std");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const compiler = @import("compiler.zig");
const otherlibs = @import("otherlibs.zig");
const Ocamlopt = @import("ocamlopt.zig");
pub const Source = @import("source.zig");
pub const Platform = @import("platform.zig");
pub const Versions = @import("versions.zig");
pub const Version = Versions.Version;
pub const resolveTarget = Platform.resolveTarget;

pub const Options = struct {
    /// Where the compilers run.
    host: std.Build.ResolvedTarget,
    /// Where the programs they produce run.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ocamldoc: bool = false,
    ocamldebug: bool = false,
    ocamlnat: bool = false,
    bytecode_tools: bool = false,
    runtime_variants: bool = false,
};

pub const MatrixOptions = struct {
    optimize: std.builtin.OptimizeMode,
    ocamldoc: bool = true,
    ocamldebug: bool = true,
    ocamlnat: bool = true,
    bytecode_tools: bool = true,
    runtime_variants: bool = true,
};

pub const Pair = struct {
    host: []const u8,
    target: []const u8,
};

pub const all_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "riscv64-linux-gnu",
    "powerpc64le-linux-gnu",
    "s390x-linux-gnu",
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "riscv64-linux-musl",
    "powerpc64le-linux-musl",
    "s390x-linux-musl",
    "aarch64-macos",
    "x86_64-macos",
    "x86_64-windows-gnu",
};

/// Static list of `(host, target)` pairs built by `zig build matrix`.
pub const matrix_pairs = blk: {
    var pairs: []const Pair = &.{};
    // 1. All self-hosted toolchains (T -> T)
    for (all_targets) |t| {
        pairs = pairs ++ .{Pair{ .host = t, .target = t }};
    }
    // 2. x86_64-linux-gnu -> all other targets
    for (all_targets) |t| {
        if (!std.mem.eql(u8, t, "x86_64-linux-gnu")) {
            pairs = pairs ++ .{Pair{ .host = "x86_64-linux-gnu", .target = t }};
        }
    }
    // 3. Common cross-compilation pairs from other primary hosts
    for ([_]Pair{
        // aarch64-linux-gnu host
        .{ .host = "aarch64-linux-gnu", .target = "x86_64-linux-gnu" },
        .{ .host = "aarch64-linux-gnu", .target = "aarch64-linux-musl" },
        .{ .host = "aarch64-linux-gnu", .target = "riscv64-linux-gnu" },
        .{ .host = "aarch64-linux-gnu", .target = "aarch64-macos" },
        .{ .host = "aarch64-linux-gnu", .target = "x86_64-windows-gnu" },
        // aarch64-macos host
        .{ .host = "aarch64-macos", .target = "x86_64-macos" },
        .{ .host = "aarch64-macos", .target = "x86_64-linux-gnu" },
        .{ .host = "aarch64-macos", .target = "aarch64-linux-gnu" },
        .{ .host = "aarch64-macos", .target = "x86_64-linux-musl" },
        .{ .host = "aarch64-macos", .target = "aarch64-linux-musl" },
        .{ .host = "aarch64-macos", .target = "x86_64-windows-gnu" },
        // x86_64-macos host
        .{ .host = "x86_64-macos", .target = "aarch64-macos" },
        .{ .host = "x86_64-macos", .target = "x86_64-linux-gnu" },
        .{ .host = "x86_64-macos", .target = "aarch64-linux-gnu" },
        // musl hosts
        .{ .host = "x86_64-linux-musl", .target = "aarch64-linux-musl" },
        .{ .host = "x86_64-linux-musl", .target = "riscv64-linux-musl" },
        .{ .host = "x86_64-linux-musl", .target = "x86_64-linux-gnu" },
        .{ .host = "aarch64-linux-musl", .target = "x86_64-linux-musl" },
        .{ .host = "aarch64-linux-musl", .target = "aarch64-linux-gnu" },
        // x86_64-windows-gnu host
        .{ .host = "x86_64-windows-gnu", .target = "x86_64-linux-gnu" },
        .{ .host = "x86_64-windows-gnu", .target = "aarch64-linux-gnu" },
    }) |p| {
        pairs = pairs ++ .{p};
    }
    break :blk pairs;
};

pub const Toolchain = struct {
    b: *std.Build,
    /// The install tree, see the module docs.
    layout: std.Build.LazyPath,
    host_rt: runtime.Artifacts,
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    compiler: compiler.Artifacts,
    otherlibs: otherlibs.Artifacts,
    ocamldebug: ?compiler.DebuggerArtifacts = null,
    ocamldoc: ?compiler.OcamldocArtifacts = null,
    options: Options,

    /// Install the layout to `<install prefix>/<sub_path>`.
    pub fn addInstall(self: Toolchain, step: *std.Build.Step, sub_path: []const u8) void {
        step.dependOn(&self.b.addInstallDirectory(.{
            .source_dir = self.layout,
            .install_dir = .prefix,
            .install_subdir = sub_path,
        }).step);
    }
};

/// Memoizes shared build artifacts (runtimes, stdlib, bytecode/native compiler waves,
/// and build-host native emitters) across one or more `(host, target)` toolchains.
pub const Context = struct {
    src: *const Source,
    opts: MatrixOptions,
    build_platform: Platform,
    build_rt: runtime.Artifacts,
    stdlib_common: stdlib.Common,
    comp_shared: compiler.Shared,
    frontend_byte: ?compiler.ArchByte = null,
    base_dbg: ?compiler.DebuggerArtifacts = null,
    odoc_byte: ?compiler.OcamldocByte = null,
    runtimes: std.StringHashMapUnmanaged(runtime.Artifacts) = .empty,
    byte_stdlibs: std.StringHashMapUnmanaged(stdlib.Artifacts) = .empty,
    nat_stdlib_dirs: std.StringHashMapUnmanaged(std.Build.LazyPath) = .empty,
    arch_bytes: std.AutoHashMapUnmanaged(?Platform.Arch, compiler.ArchByte) = .empty,
    byte_comps: std.StringHashMapUnmanaged(compiler.Artifacts) = .empty,
    emitters: std.StringHashMapUnmanaged(Emitter) = .empty,
    target_arch_nats: std.StringHashMapUnmanaged(compiler.ArchNative) = .empty,
    odoc_nats: std.StringHashMapUnmanaged(compiler.OcamldocNative) = .empty,
    targets: std.StringHashMapUnmanaged(TargetBundle) = .empty,
    cross_arch_nats: std.StringHashMapUnmanaged(compiler.ArchNative) = .empty,
    toolchains: std.StringHashMapUnmanaged(Toolchain) = .empty,

    const Emitter = struct {
        raw_opt: Ocamlopt,
        native_programs: compiler.NativePrograms,
    };

    const TargetBundle = struct {
        rt: runtime.Artifacts,
        stdlib: stdlib.Artifacts,
        libs: otherlibs.Artifacts,
        arch_nat: ?compiler.ArchNative,
        emitter: ?Ocamlopt,
        toolchain: Toolchain,
    };

    pub fn init(src: *const Source, opts: MatrixOptions) Context {
        const b = src.b;
        const build_platform: Platform = .init(b, resolveTarget(b, "native"));
        const build_rt = runtime.build(src.*, .{
            .platform = build_platform,
            .optimize = opts.optimize,
            .variants = opts.runtime_variants,
        });
        const stdlib_common = stdlib.buildCommon(src, build_rt.primitives, build_rt.ocamlrun);
        const comp_shared = compiler.buildShared(src, stdlib_common.base_dir, stdlib_common.build_launch_info_dir, build_rt.primitives, build_rt.ocamlrun, build_rt.ocamlyacc);
        var ctx: Context = .{
            .src = src,
            .opts = opts,
            .build_platform = build_platform,
            .build_rt = build_rt,
            .stdlib_common = stdlib_common,
            .comp_shared = comp_shared,
        };
        ctx.runtimes.put(b.allocator, build_platform.triplet, build_rt) catch @panic("OOM");
        return ctx;
    }

    fn getRuntime(self: *Context, p: Platform) runtime.Artifacts {
        if (self.runtimes.get(p.triplet)) |rt| return rt;
        const rt = runtime.build(self.src.*, .{
            .platform = p,
            .optimize = self.opts.optimize,
            .variants = self.opts.runtime_variants,
        });
        self.runtimes.put(self.src.b.allocator, p.triplet, rt) catch @panic("OOM");
        return rt;
    }

    fn getByteStdlib(self: *Context, p: Platform) stdlib.Artifacts {
        if (self.byte_stdlibs.get(p.triplet)) |s| return s;
        const s = stdlib.buildForTarget(self.src, self.stdlib_common, self.getRuntime(p));
        self.byte_stdlibs.put(self.src.b.allocator, p.triplet, s) catch @panic("OOM");
        return s;
    }

    fn getArchByte(self: *Context, arch: ?Platform.Arch) compiler.ArchByte {
        if (self.arch_bytes.get(arch)) |ab| return ab;
        if (self.frontend_byte == null and arch != null and self.build_platform.arch != null and arch.? != self.build_platform.arch.?) {
            _ = self.getArchByte(self.build_platform.arch);
        }
        const ab = compiler.buildArchByte(self.src, self.comp_shared, arch, self.frontend_byte);
        if (self.frontend_byte == null and arch != null) self.frontend_byte = ab;
        self.arch_bytes.put(self.src.b.allocator, arch, ab) catch @panic("OOM");
        return ab;
    }

    fn getByteComp(self: *Context, host: Platform, target: Platform, target_stdlib_dir: std.Build.LazyPath) compiler.Artifacts {
        const b = self.src.b;
        const key = b.fmt("{s}->{s}", .{ host.triplet, target.triplet });
        if (self.byte_comps.get(key)) |c| {
            var out = c;
            out.ocamlopt.stdlib_dir = target_stdlib_dir;
            out.ocamlc.stdlib_dir = target_stdlib_dir;
            return out;
        }
        const c = compiler.buildFromArchByte(
            self.src,
            self.comp_shared,
            self.getArchByte(target.arch),
            host,
            target,
            self.getByteStdlib(host).launch_info_dir,
            target_stdlib_dir,
        );
        self.byte_comps.put(b.allocator, key, c) catch @panic("OOM");
        return c;
    }

    fn getCrossArchNative(self: *Context, host: Platform, target_arch: ?Platform.Arch) compiler.ArchNative {
        const b = self.src.b;
        const key = b.fmt("{s}->{s}", .{ host.triplet, if (target_arch) |a| @tagName(a) else "none" });
        if (self.cross_arch_nats.get(key)) |an| return an;
        const h_bundle = self.getTarget(host);
        if (target_arch != null and host.arch != null and target_arch.? == host.arch.?) {
            return h_bundle.arch_nat.?;
        }
        const an = compiler.buildArchNative(self.src, self.getArchByte(target_arch), null, h_bundle.emitter.?, null, h_bundle.arch_nat);
        self.cross_arch_nats.put(b.allocator, key, an) catch @panic("OOM");
        return an;
    }

    fn codeKey(self: *Context, p: Platform) []const u8 {
        return self.src.b.fmt("{s}-{s}", .{ p.archName(), p.system });
    }

    fn getNativeStdlib(self: *Context, target: Platform, byte_stdlib: stdlib.Artifacts, opt: Ocamlopt) stdlib.Artifacts {
        if (!target.hasNativeCompiler()) return byte_stdlib;
        const b = self.src.b;
        const key = self.codeKey(target);
        const nat_dir = self.nat_stdlib_dirs.get(key) orelse blk: {
            const d = stdlib.buildNativeDir(self.src, byte_stdlib, opt, target);
            self.nat_stdlib_dirs.put(b.allocator, key, d) catch @panic("OOM");
            break :blk d;
        };
        return stdlib.attachNativeDir(b, byte_stdlib, nat_dir);
    }

    fn getTargetArchNative(self: *Context, target: Platform, arch_byte: compiler.ArchByte, opt: Ocamlopt, dynlink_dir: std.Build.LazyPath) compiler.ArchNative {
        const key = self.codeKey(target);
        if (self.target_arch_nats.get(key)) |an| return an;
        const an = compiler.buildArchNative(self.src, arch_byte, self.comp_shared.lex, opt, dynlink_dir, null);
        self.target_arch_nats.put(self.src.b.allocator, key, an) catch @panic("OOM");
        return an;
    }

    fn getOcamldoc(self: *Context, comp: compiler.Artifacts, libs: otherlibs.Artifacts, rt: runtime.Artifacts, host: Platform, host_launch_info_dir: ?std.Build.LazyPath) compiler.OcamldocArtifacts {
        const odoc_byte = self.odoc_byte orelse blk: {
            const ob = compiler.buildOcamldocByte(self.src, comp, libs, self.build_rt.ocamlrun, self.build_rt.ocamlyacc);
            self.odoc_byte = ob;
            break :blk ob;
        };
        const odoc_nat: ?compiler.OcamldocNative = if (rt.platform.hasNativeCompiler()) blk: {
            const key = self.codeKey(rt.platform);
            if (self.odoc_nats.get(key)) |on| break :blk on;
            const on = compiler.buildOcamldocNative(self.src, odoc_byte, comp, libs);
            self.odoc_nats.put(self.src.b.allocator, key, on) catch @panic("OOM");
            break :blk on;
        } else null;
        return compiler.linkOcamldoc(self.src, odoc_byte, odoc_nat, comp, libs, rt, host, host_launch_info_dir);
    }

    fn getDebugger(self: *Context, comp: compiler.Artifacts, libs: otherlibs.Artifacts, host: Platform, host_launch_info_dir: ?std.Build.LazyPath) compiler.DebuggerArtifacts {
        if (self.base_dbg) |base| {
            return compiler.relinkDebugger(self.src, base, comp, libs, host, host_launch_info_dir);
        }
        const dbg = compiler.buildDebugger(self.src, comp, libs, host, self.build_rt.ocamlrun, self.build_rt.ocamlyacc);
        self.base_dbg = dbg;
        return dbg;
    }

    fn getEmitter(self: *Context, target: Platform) Emitter {
        if (self.emitters.get(target.triplet)) |em| return em;
        const b = self.src.b;
        const b_bundle = self.getTarget(self.build_platform);
        const cross_arch_nat = self.getCrossArchNative(self.build_platform, target.arch);
        const b_to_t_byte = self.getByteComp(self.build_platform, target, self.getByteStdlib(target).dir);
        const b_to_t_nat = compiler.finishNative(
            self.src,
            b_to_t_byte,
            cross_arch_nat,
            b_bundle.emitter.?,
            b_bundle.rt,
            null,
            true,
            b_bundle.toolchain.compiler.native_programs.?.ocamllex,
        );
        const em: Emitter = .{
            .raw_opt = .{
                .b = b,
                .ocamlrun = null,
                .exe = b_to_t_nat.native_programs.?.ocamlopt,
                .stdlib_dir = null,
                .prefix_map = self.src.prefixMap(),
                .cwd = self.src.path(""),
            },
            .native_programs = b_to_t_nat.native_programs.?,
        };
        self.emitters.put(b.allocator, target.triplet, em) catch @panic("OOM");
        return em;
    }

    fn getTarget(self: *Context, target: Platform) TargetBundle {
        if (self.targets.get(target.triplet)) |tb| return tb;
        const b = self.src.b;
        const rt = self.getRuntime(target);
        const byte_stdlib = self.getByteStdlib(target);
        const arch_byte = self.getArchByte(target.arch);

        const raw_emitter: ?Ocamlopt = if (!target.eql(self.build_platform) and target.hasNativeCompiler() and self.build_platform.hasNativeCompiler())
            self.getEmitter(target).raw_opt
        else
            null;

        var comp = self.getByteComp(target, target, byte_stdlib.dir);
        const boot_opt = raw_emitter orelse comp.ocamlopt;
        const std_lib = self.getNativeStdlib(target, byte_stdlib, boot_opt);

        var opt = boot_opt;
        opt.stdlib_dir = std_lib.dir;
        comp.ocamlopt = opt;
        comp.ocamlc.stdlib_dir = std_lib.dir;

        const libs = otherlibs.build(self.src, .{
            .target_rt = rt,
            .stdlib = std_lib,
            .compiler = comp,
            .optimize = self.opts.optimize,
        });

        var arch_nat: ?compiler.ArchNative = null;
        var emitter: ?Ocamlopt = null;
        if (target.hasNativeCompiler()) {
            arch_nat = self.getTargetArchNative(target, arch_byte, opt, libs.dynlink_dir);
            comp = compiler.finishNative(self.src, comp, arch_nat.?, opt, rt, libs.dynlink_dir, true, null);
            emitter = if (target.eql(self.build_platform)) .{
                .b = b,
                .ocamlrun = null,
                .exe = comp.native_programs.?.ocamlopt,
                .stdlib_dir = std_lib.dir,
                .prefix_map = self.src.prefixMap(),
                .cwd = self.src.path(""),
            } else opt;
            comp.ocamlopt = emitter.?;
        }

        const ocamldebug = if (self.opts.ocamldebug)
            self.getDebugger(comp, libs, target, byte_stdlib.launch_info_dir)
        else
            null;
        const ocamldoc = if (self.opts.ocamldoc)
            self.getOcamldoc(comp, libs, rt, target, byte_stdlib.launch_info_dir)
        else
            null;

        const tc_opts: Options = .{
            .host = target.resolved,
            .target = target.resolved,
            .optimize = self.opts.optimize,
            .ocamldoc = self.opts.ocamldoc,
            .ocamldebug = self.opts.ocamldebug,
            .ocamlnat = self.opts.ocamlnat,
            .bytecode_tools = self.opts.bytecode_tools,
            .runtime_variants = self.opts.runtime_variants,
        };
        var tc: Toolchain = .{
            .b = b,
            .layout = undefined,
            .host_rt = rt,
            .target_rt = rt,
            .stdlib = std_lib,
            .compiler = comp,
            .otherlibs = libs,
            .ocamldebug = ocamldebug,
            .ocamldoc = ocamldoc,
            .options = tc_opts,
        };
        tc.layout = assembleLayout(self.src.*, tc);

        const bundle: TargetBundle = .{
            .rt = rt,
            .stdlib = std_lib,
            .libs = libs,
            .arch_nat = arch_nat,
            .emitter = emitter,
            .toolchain = tc,
        };
        self.targets.put(b.allocator, target.triplet, bundle) catch @panic("OOM");
        const pair_key = b.fmt("{s}->{s}", .{ target.triplet, target.triplet });
        self.toolchains.put(b.allocator, pair_key, tc) catch @panic("OOM");
        return bundle;
    }

    pub fn build(self: *Context, host_resolved: std.Build.ResolvedTarget, target_resolved: std.Build.ResolvedTarget) Toolchain {
        const b = self.src.b;
        const host: Platform = .init(b, host_resolved);
        const target: Platform = .init(b, target_resolved);
        if (host.eql(target)) return self.getTarget(target).toolchain;

        const pair_key = b.fmt("{s}->{s}", .{ host.triplet, target.triplet });
        if (self.toolchains.get(pair_key)) |tc| return tc;

        const h_bundle = self.getTarget(host);
        const t_bundle = self.getTarget(target);
        var comp = self.getByteComp(host, target, t_bundle.stdlib.dir);

        if (target.hasNativeCompiler()) {
            comp = compiler.finishNative(self.src, comp, t_bundle.arch_nat.?, t_bundle.emitter.?, t_bundle.rt, t_bundle.libs.dynlink_dir, false, null);
            comp.ocamlnat = t_bundle.toolchain.compiler.ocamlnat;
            comp.profiling_dir = t_bundle.toolchain.compiler.profiling_dir;
        }
        if (host.hasNativeCompiler()) {
            if (host.eql(self.build_platform) and target.hasNativeCompiler()) {
                comp.native_programs = self.getEmitter(target).native_programs;
            } else {
                const cross_arch_nat = self.getCrossArchNative(host, target.arch);
                const host_nat = compiler.finishNative(
                    self.src,
                    comp,
                    cross_arch_nat,
                    h_bundle.emitter.?,
                    h_bundle.rt,
                    null,
                    true,
                    h_bundle.toolchain.compiler.native_programs.?.ocamllex,
                );
                comp.native_programs = host_nat.native_programs;
            }
        }

        const ocamldebug = if (self.opts.ocamldebug)
            compiler.relinkDebugger(self.src, t_bundle.toolchain.ocamldebug.?, comp, t_bundle.libs, host, h_bundle.stdlib.launch_info_dir)
        else
            null;
        const ocamldoc = if (self.opts.ocamldoc)
            compiler.relinkOcamldoc(self.src, t_bundle.toolchain.ocamldoc.?, comp, t_bundle.libs, t_bundle.rt, host, h_bundle.stdlib.launch_info_dir)
        else
            null;

        const tc_opts: Options = .{
            .host = host_resolved,
            .target = target_resolved,
            .optimize = self.opts.optimize,
            .ocamldoc = self.opts.ocamldoc,
            .ocamldebug = self.opts.ocamldebug,
            .ocamlnat = self.opts.ocamlnat,
            .bytecode_tools = self.opts.bytecode_tools,
            .runtime_variants = self.opts.runtime_variants,
        };
        var tc: Toolchain = .{
            .b = b,
            .layout = undefined,
            .host_rt = h_bundle.rt,
            .target_rt = t_bundle.rt,
            .stdlib = t_bundle.stdlib,
            .compiler = comp,
            .otherlibs = t_bundle.libs,
            .ocamldebug = ocamldebug,
            .ocamldoc = ocamldoc,
            .options = tc_opts,
        };
        tc.layout = assembleLayout(self.src.*, tc);
        self.toolchains.put(b.allocator, pair_key, tc) catch @panic("OOM");
        return tc;
    }
};

/// Get `src` from `Versions.source`.
pub fn build(src: *const Source, options: Options) Toolchain {
    var ctx = Context.init(src, .{
        .optimize = options.optimize,
        .ocamldoc = options.ocamldoc,
        .ocamldebug = options.ocamldebug,
        .ocamlnat = options.ocamlnat,
        .bytecode_tools = options.bytecode_tools,
        .runtime_variants = options.runtime_variants,
    });
    return ctx.build(options.host, options.target);
}

/// Build and install all `(host, target)` pairs in `matrix_pairs` to `step`.
pub fn buildMatrix(src: *const Source, step: *std.Build.Step, version: Version, options: MatrixOptions) void {
    const b = src.b;
    var ctx = Context.init(src, options);
    for (matrix_pairs) |pair| {
        const host = resolveTarget(b, pair.host);
        const target = resolveTarget(b, pair.target);
        const tc = ctx.build(host, target);
        const sub_path = b.fmt(
            "{t}/host-{s}/target-{s}",
            .{ version, host.result.linuxTriple(b.allocator) catch @panic("OOM"), target.result.linuxTriple(b.allocator) catch @panic("OOM") },
        );
        tc.addInstall(step, sub_path);
    }
}

const Layout = struct {
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,

    fn file(self: Layout, src: std.Build.LazyPath, dest: []const u8) void {
        _ = self.wf.addCopyFile(src, dest);
    }

    fn dir(self: Layout, src: std.Build.LazyPath, dest: []const u8, exclude_extensions: []const []const u8) void {
        _ = self.wf.addCopyDirectory(src, dest, .{ .exclude_extensions = exclude_extensions });
    }

    /// Install a compiled artifact, using `lib<name>.a` for static archives (as OCaml expects on mingw).
    fn artifact(self: Layout, a: *std.Build.Step.Compile, dest_dir: []const u8) void {
        const name = if (a.kind == .lib and a.linkage == .static)
            self.b.fmt("lib{s}.a", .{a.name})
        else
            a.out_filename;
        self.file(a.getEmittedBin(), self.b.fmt("{s}/{s}", .{ dest_dir, name }));
    }
};

fn assembleLayout(src: Source, tc: Toolchain) std.Build.LazyPath {
    const b = src.b;
    const host_exe = tc.host_rt.platform.exeExt();
    const target = tc.target_rt.platform;
    const target_exe = target.exeExt();
    const layout: Layout = .{ .b = b, .wf = b.addWriteFiles() };
    const bin = "bin";
    const lib = "lib/ocaml";

    // bin/: host runtime and tools (.opt defaults, with .byte always retained)
    layout.artifact(tc.host_rt.ocamlrun, bin);
    if (tc.host_rt.ocamlrund) |a| layout.artifact(a, bin);
    if (tc.host_rt.ocamlruni) |a| layout.artifact(a, bin);
    layout.artifact(tc.host_rt.ocamlyacc, bin);
    if (!tc.host_rt.platform.eql(target)) {
        layout.file(tc.target_rt.ocamlrun.getEmittedBin(), b.fmt("{s}/ocamlrun-target{s}", .{ bin, target_exe }));
        if (tc.target_rt.ocamlrund) |a| layout.file(a.getEmittedBin(), b.fmt("{s}/ocamlrund-target{s}", .{ bin, target_exe }));
        if (tc.target_rt.ocamlruni) |a| layout.file(a.getEmittedBin(), b.fmt("{s}/ocamlruni-target{s}", .{ bin, target_exe }));
    }

    const progs = tc.compiler.programs;
    // also installed as `<name>.byte`, upstream's name for the bytecode build
    // (ocamlc.byte and ocamlopt.byte are debug-stripped, matching upstream install)
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "ocamlc", progs.ocamlc_stripped },
        .{ "ocamlopt", progs.ocamlopt_stripped },
        .{ "ocamllex", progs.ocamllex },
        .{ "ocamldep", progs.ocamldep },
        .{ "ocamlobjinfo", progs.ocamlobjinfo },
    }) |entry| {
        const native = if (tc.compiler.native_programs) |p| blk: {
            inline for (comptime std.meta.fieldNames(compiler.NativePrograms)) |name| {
                if (std.mem.eql(u8, name, entry[0])) break :blk @field(p, name);
            }
            unreachable;
        } else null;
        layout.file(native orelse entry[1], b.fmt("{s}/{s}{s}", .{ bin, entry[0], host_exe }));
        if (native) |exe| layout.file(exe, b.fmt("{s}/{s}.opt{s}", .{ bin, entry[0], host_exe }));
        layout.file(entry[1], b.fmt("{s}/{s}.byte{s}", .{ bin, entry[0], host_exe }));
    }
    if (tc.options.ocamlnat) {
        if (tc.compiler.ocamlnat) |exe| layout.file(exe, b.fmt("{s}/ocamlnat{s}", .{ bin, target_exe }));
    }
    if (tc.ocamldebug) |dbg| {
        layout.file(dbg.exe, b.fmt("{s}/ocamldebug{s}", .{ bin, host_exe }));
        layout.file(dbg.cmi, lib ++ "/compiler-libs/ocamldebug.cmi");
        layout.file(dbg.parser_aux_cmi, lib ++ "/compiler-libs/parser_aux.cmi");
    }
    if (tc.ocamldoc) |odoc| {
        const default_odoc = if (tc.host_rt.platform.eql(target)) odoc.opt orelse odoc.byte else odoc.byte;
        layout.file(default_odoc, b.fmt("{s}/ocamldoc{s}", .{ bin, host_exe }));
        if (odoc.opt) |exe| layout.file(exe, b.fmt("{s}/ocamldoc.opt{s}", .{ bin, target_exe }));
        layout.file(odoc.byte, b.fmt("{s}/ocamldoc.byte{s}", .{ bin, host_exe }));
        layout.dir(odoc.lib_dir, lib ++ "/ocamldoc", &.{});
    }
    if (tc.options.bytecode_tools) {
        for ([_]struct { []const u8, std.Build.LazyPath }{
            .{ "cmpbyt", progs.cmpbyt },
            .{ "dumpobj", progs.dumpobj },
            .{ "primreq", progs.primreq },
            .{ "stripdebug", progs.stripdebug },
        }) |entry| {
            layout.file(entry[1], b.fmt("{s}/{s}{s}", .{ bin, entry[0], host_exe }));
        }
    }
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "ocamlcmt", progs.ocamlcmt },
        .{ "ocamlprof", progs.ocamlprof },
        .{ "ocamlcp", progs.ocamlcp },
        .{ "ocamloptp", progs.ocamloptp },
        .{ "ocamlmklib", progs.ocamlmklib },
        .{ "ocamlmktop", progs.ocamlmktop },
        .{ "ocaml", progs.ocaml },
    }) |entry| {
        layout.file(entry[1], b.fmt("{s}/{s}{s}", .{ bin, entry[0], host_exe }));
    }
    layout.file(progs.expunge, b.fmt("{s}/expunge{s}", .{ lib, host_exe }));

    // lib/ocaml/: target runtime libraries, primitives, ld.conf, C headers
    layout.artifact(tc.target_rt.libcamlrun, lib);
    if (tc.target_rt.libcamlrun_pic) |a| layout.artifact(a, lib);
    if (tc.target_rt.libcamlrun_shared) |a| layout.artifact(a, lib);
    if (tc.target_rt.libcamlrund) |a| layout.artifact(a, lib);
    if (tc.target_rt.libcamlruni) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrun) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrun_pic) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrun_shared) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmrund) |a| layout.artifact(a, lib);
    if (tc.target_rt.libasmruni) |a| layout.artifact(a, lib);
    layout.artifact(tc.target_rt.libcomprmarsh, lib);
    layout.artifact(tc.target_rt.zstd_lib, lib);
    layout.file(tc.target_rt.primitives, lib ++ "/primitives");
    layout.file(b.addWriteFiles().add("ld.conf", "./stublibs\n.\n"), lib ++ "/ld.conf");
    layout.dir(src.path("runtime/caml"), lib ++ "/caml", &.{ ".in", "dune" });
    layout.dir(tc.target_rt.headers_dir.path(b, "caml"), lib ++ "/caml", &.{});

    // stdlib (flat in lib/ocaml/, as upstream)
    layout.dir(tc.stdlib.dir, lib, &.{});
    layout.file(tc.stdlib.meta, lib ++ "/stdlib/META");

    // compiler-libs, profiling
    layout.dir(tc.compiler.compilerlibs_dir, lib ++ "/compiler-libs", &.{});
    layout.dir(tc.compiler.profiling_dir, lib ++ "/profiling", &.{});

    // otherlibs: lib/ocaml/<lib>/, C stubs in lib/ocaml/ and lib/ocaml/stublibs/
    for (tc.otherlibs.libs) |l| {
        layout.dir(l.dir, b.fmt("{s}/{s}", .{ lib, l.name }), &.{});
        const stubs = l.stubs orelse continue;
        layout.artifact(stubs.static_byt, lib);
        layout.artifact(stubs.static_nat, lib);
        if (stubs.shared_byt) |dll| layout.file(dll.getEmittedBin(), b.fmt("{s}/stublibs/{s}", .{ lib, stubs.dllName(target) }));
    }
    for (tc.otherlibs.headers) |h| layout.file(h.source, b.fmt("{s}/caml/{s}", .{ lib, h.dest_name }));

    return layout.wf.getDirectory();
}
