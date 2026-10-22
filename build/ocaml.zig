const std = @import("std");
const target_config = @import("target_config.zig");
const source_info = @import("source_info.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const compiler = @import("compiler.zig");
const otherlibs = @import("otherlibs.zig");

pub const TargetConfig = target_config.TargetConfig;
pub const SourceInfo = source_info.SourceInfo;
pub const RuntimeArtifacts = runtime.RuntimeArtifacts;
pub const StdlibArtifacts = stdlib.StdlibArtifacts;
pub const CompilerArtifacts = compiler.CompilerArtifacts;
pub const OtherlibsArtifacts = otherlibs.OtherlibsArtifacts;

const Self = @This();

b: *std.Build,
dep: *std.Build.Dependency,
src_info: SourceInfo,

pub fn init(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
) *Self {
    const self = b.allocator.create(Self) catch @panic("OOM");
    self.* = .{
        .b = b,
        .dep = ocaml_dep,
        .src_info = SourceInfo.load(b, ocaml_dep),
    };
    return self;
}

pub const BuildOptions = struct {
    /// The target where the ocaml compiler runs.
    compiler_host: std.Build.ResolvedTarget,
    /// The target where the output of the ocaml compiler runs.
    compiler_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Optional sub-prefix under zig-out used to compute default runtime/stdlib paths.
    prefix: ?[]const u8 = null,
};

pub const InstallOptions = struct {
    /// Optional prefix relative to the install root (e.g. "5.5.1/host-.../target-...").
    /// When null, installs into standard `bin/` and `lib/ocaml/` under the install prefix.
    prefix: ?[]const u8 = null,
};

pub const Toolchain = struct {
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    src_info: SourceInfo,
    host_cfg: TargetConfig,
    target_cfg: TargetConfig,
    host_rt: RuntimeArtifacts,
    target_rt: RuntimeArtifacts,
    target_stdlib: StdlibArtifacts,
    target_compiler: CompilerArtifacts,
    target_otherlibs: OtherlibsArtifacts,
    ld_conf: std.Build.LazyPath,

    pub fn addInstall(self: Toolchain, step: *std.Build.Step, options: InstallOptions) void {
        const b = self.b;

        const bin_dir: std.Build.InstallDir = if (options.prefix) |p|
            .{ .custom = b.fmt("{s}/bin", .{p}) }
        else
            .bin;

        const ocaml_lib_dir: std.Build.InstallDir = if (options.prefix) |p|
            .{ .custom = b.fmt("{s}/lib/ocaml", .{p}) }
        else
            .{ .custom = "lib/ocaml" };

        const stublibs_dir: std.Build.InstallDir = if (options.prefix) |p|
            .{ .custom = b.fmt("{s}/lib/ocaml/stublibs", .{p}) }
        else
            .{ .custom = "lib/ocaml/stublibs" };

        // 1. Host runtime & yacc binaries -> <prefix>/bin/
        step.dependOn(&b.addInstallArtifact(self.host_rt.ocamlrun, .{
            .dest_dir = .{ .override = bin_dir },
            .pdb_dir = .disabled,
        }).step);
        step.dependOn(&b.addInstallArtifact(self.host_rt.ocamlyacc, .{
            .dest_dir = .{ .override = bin_dir },
            .pdb_dir = .disabled,
        }).step);
        if (!std.mem.eql(u8, self.host_cfg.triplet, self.target_cfg.triplet)) {
            const target_exe_ext = if (self.target_cfg.is_windows) ".exe" else "";
            step.dependOn(&b.addInstallFileWithDir(
                self.target_rt.ocamlrun.getEmittedBin(),
                bin_dir,
                b.fmt("ocamlrun-target{s}", .{target_exe_ext}),
            ).step);
        }

        // 2. Bytecode compilers & tools -> <prefix>/bin/
        const tc = self.target_compiler;
        const dual_tools = [_]struct { name: []const u8, lp: std.Build.LazyPath }{
            .{ .name = "ocamlc", .lp = tc.ocamlc_byte },
            .{ .name = "ocamlopt", .lp = tc.ocamlopt_byte },
            .{ .name = "ocamllex", .lp = tc.ocamllex_byte },
            .{ .name = "ocamldep", .lp = tc.ocamldep_byte },
            .{ .name = "ocamlobjinfo", .lp = tc.ocamlobjinfo_byte },
        };
        for (dual_tools) |tool| {
            const byte_name = b.fmt("{s}.byte", .{tool.name});
            step.dependOn(&b.addInstallFileWithDir(tool.lp, bin_dir, byte_name).step);
            step.dependOn(&b.addInstallFileWithDir(tool.lp, bin_dir, tool.name).step);
        }

        const byt_only_tools = [_]struct { name: []const u8, lp: std.Build.LazyPath }{
            .{ .name = "ocamlcmt", .lp = tc.ocamlcmt_byte },
            .{ .name = "ocamlprof", .lp = tc.ocamlprof_byte },
            .{ .name = "ocamlcp", .lp = tc.ocamlcp_byte },
            .{ .name = "ocamloptp", .lp = tc.ocamloptp_byte },
            .{ .name = "ocamlmklib", .lp = tc.ocamlmklib_byte },
            .{ .name = "ocamlmktop", .lp = tc.ocamlmktop_byte },
        };
        for (byt_only_tools) |tool| {
            step.dependOn(&b.addInstallFileWithDir(tool.lp, bin_dir, tool.name).step);
        }

        step.dependOn(&b.addInstallFileWithDir(tc.ocaml_toplevel, bin_dir, "ocaml").step);
        step.dependOn(&b.addInstallFileWithDir(tc.expunge_byte, ocaml_lib_dir, "expunge").step);

        // 3. Runtime static libraries -> <prefix>/lib/ocaml/
        step.dependOn(&b.addInstallArtifact(self.target_rt.libcamlrun, .{
            .dest_dir = .{ .override = ocaml_lib_dir },
        }).step);
        if (self.target_rt.libasmrun) |asmrun| {
            step.dependOn(&b.addInstallArtifact(asmrun, .{
                .dest_dir = .{ .override = ocaml_lib_dir },
            }).step);
        }
        if (self.target_rt.libcomprmarsh) |comprmarsh| {
            step.dependOn(&b.addInstallArtifact(comprmarsh, .{
                .dest_dir = .{ .override = ocaml_lib_dir },
            }).step);
        }

        // 4. Primitives, ld.conf, & runtime C headers -> <prefix>/lib/ocaml/
        step.dependOn(&b.addInstallFileWithDir(
            self.target_rt.primitives,
            ocaml_lib_dir,
            "primitives",
        ).step);
        step.dependOn(&b.addInstallFileWithDir(
            self.ld_conf,
            ocaml_lib_dir,
            "ld.conf",
        ).step);
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = self.ocaml_dep.path("runtime/caml"),
            .install_dir = ocaml_lib_dir,
            .install_subdir = "caml",
            .exclude_extensions = &.{ ".in", "dune" },
        }).step);
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = self.target_rt.headers_dir.path(b, "caml"),
            .install_dir = ocaml_lib_dir,
            .install_subdir = "caml",
        }).step);

        // 5. Standard library -> <prefix>/lib/ocaml/ and <prefix>/lib/ocaml/stdlib/META
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = self.target_stdlib.stdlib_dir,
            .install_dir = ocaml_lib_dir,
            .install_subdir = "",
        }).step);
        step.dependOn(&b.addInstallFileWithDir(
            self.target_stdlib.meta_file,
            ocaml_lib_dir,
            "stdlib/META",
        ).step);

        // 6. Compilerlibs -> <prefix>/lib/ocaml/compiler-libs/ and profiling -> <prefix>/lib/ocaml/profiling/
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = tc.compilerlibs_dir,
            .install_dir = ocaml_lib_dir,
            .install_subdir = "compiler-libs",
        }).step);
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = tc.profiling_dir,
            .install_dir = ocaml_lib_dir,
            .install_subdir = "profiling",
        }).step);

        // 7. Otherlibs -> <prefix>/lib/ocaml/<lib>/, C stubs -> <prefix>/lib/ocaml/ and stublibs/
        const ol = self.target_otherlibs;
        const otherlib_dirs = [_]struct { name: []const u8, dir: std.Build.LazyPath }{
            .{ .name = "dynlink", .dir = ol.dynlink_dir },
            .{ .name = "unix", .dir = ol.unix_dir },
            .{ .name = "str", .dir = ol.str_dir },
            .{ .name = "threads", .dir = ol.threads_dir },
            .{ .name = "runtime_events", .dir = ol.runtime_events_dir },
        };
        for (otherlib_dirs) |lib| {
            step.dependOn(&b.addInstallDirectory(.{
                .source_dir = lib.dir,
                .install_dir = ocaml_lib_dir,
                .install_subdir = lib.name,
            }).step);
        }

        const static_stubs = [_]*std.Build.Step.Compile{
            ol.libunix_byt,
            ol.libunix_nat,
            ol.libstr_byt,
            ol.libstr_nat,
            ol.libthreads_byt,
            ol.libthreads_nat,
            ol.libruntime_events_byt,
            ol.libruntime_events_nat,
        };
        for (static_stubs) |st_lib| {
            step.dependOn(&b.addInstallArtifact(st_lib, .{
                .dest_dir = .{ .override = ocaml_lib_dir },
            }).step);
        }

        const is_5_1_or_newer = self.src_info.version.sem_ver.order(.{ .major = 5, .minor = 1, .patch = 0 }) != .lt;
        const dll_ext = if (self.target_cfg.is_windows) "dll" else "so";
        const dll_entries = [_]struct { art: ?*std.Build.Step.Compile, name: []const u8 }{
            .{ .art = ol.dllunix_byt, .name = if (is_5_1_or_newer) b.fmt("dllunixbyt.{s}", .{dll_ext}) else b.fmt("dllunix.{s}", .{dll_ext}) },
            .{ .art = ol.dllstr_byt, .name = if (is_5_1_or_newer) b.fmt("dllcamlstrbyt.{s}", .{dll_ext}) else b.fmt("dllcamlstr.{s}", .{dll_ext}) },
            .{ .art = ol.dllthreads_byt, .name = b.fmt("dllthreads.{s}", .{dll_ext}) },
            .{ .art = ol.dllruntime_events_byt, .name = if (is_5_1_or_newer) b.fmt("dllcamlruntime_eventsbyt.{s}", .{dll_ext}) else b.fmt("dllcamlruntime_events.{s}", .{dll_ext}) },
        };
        for (dll_entries) |entry| {
            if (entry.art) |dll| {
                step.dependOn(&b.addInstallFileWithDir(
                    dll.getEmittedBin(),
                    stublibs_dir,
                    entry.name,
                ).step);
            }
        }

        for (ol.headers) |hdr| {
            step.dependOn(&b.addInstallFileWithDir(
                hdr.source,
                ocaml_lib_dir,
                b.fmt("caml/{s}", .{hdr.dest_name}),
            ).step);
        }
    }
};

pub fn build(self: *Self, options: BuildOptions) !Toolchain {
    const b = self.b;

    const build_cfg = TargetConfig.fromTarget(b, b.graph.host, self.src_info.version);
    const host_cfg = TargetConfig.fromTarget(b, options.compiler_host, self.src_info.version);
    const target_cfg = TargetConfig.fromTarget(b, options.compiler_target, self.src_info.version);

    const bin_install_dir: std.Build.InstallDir = if (options.prefix) |p|
        .{ .custom = b.fmt("{s}/bin", .{p}) }
    else
        .bin;
    const lib_install_dir: std.Build.InstallDir = if (options.prefix) |p|
        .{ .custom = b.fmt("{s}/lib/ocaml", .{p}) }
    else
        .{ .custom = "lib/ocaml" };

    const install_bindir = b.getInstallPath(bin_install_dir, "");
    const install_libdir = b.getInstallPath(lib_install_dir, "");

    const is_5_5_or_newer = self.src_info.version.sem_ver.order(.{ .major = 5, .minor = 5, .patch = 0 }) != .lt;
    const runtime_stdlib_dir = if (is_5_5_or_newer) "../lib/ocaml" else install_libdir;

    const target_rt = try runtime.buildRuntime(b, self.dep, .{
        .src_info = self.src_info,
        .target_cfg = target_cfg,
        .optimize = options.optimize,
        .stdlib_dir = runtime_stdlib_dir,
    });

    const target_is_build = std.mem.eql(u8, target_cfg.triplet, build_cfg.triplet);
    const build_rt = if (target_is_build)
        target_rt
    else
        try runtime.buildRuntime(b, self.dep, .{
            .src_info = self.src_info,
            .target_cfg = build_cfg,
            .optimize = options.optimize,
            .stdlib_dir = runtime_stdlib_dir,
        });

    const host_rt = if (std.mem.eql(u8, host_cfg.triplet, target_cfg.triplet))
        target_rt
    else if (std.mem.eql(u8, host_cfg.triplet, build_cfg.triplet))
        build_rt
    else
        try runtime.buildRuntime(b, self.dep, .{
            .src_info = self.src_info,
            .target_cfg = host_cfg,
            .optimize = options.optimize,
            .stdlib_dir = runtime_stdlib_dir,
        });

    const target_stdlib = try stdlib.buildStdlib(b, self.dep, .{
        .src_info = self.src_info,
        .target_cfg = target_cfg,
        .target_rt = target_rt,
        .build_ocamlrun = build_rt.ocamlrun,
        .optimize = options.optimize,
        .target_bindir = install_bindir,
    });

    const target_compiler = try compiler.buildCompiler(b, self.dep, .{
        .src_info = self.src_info,
        .host_cfg = host_cfg,
        .target_cfg = target_cfg,
        .target_rt = target_rt,
        .target_stdlib = target_stdlib,
        .build_ocamlrun = build_rt.ocamlrun,
        .build_ocamlyacc = build_rt.ocamlyacc,
        .install_bindir = install_bindir,
        .install_libdir = if (is_5_5_or_newer) "../lib/ocaml" else install_libdir,
    });

    const target_otherlibs = try otherlibs.buildOtherlibs(b, self.dep, .{
        .src_info = self.src_info,
        .target_cfg = target_cfg,
        .target_rt = target_rt,
        .target_stdlib = target_stdlib,
        .compiler = target_compiler,
        .build_ocamlrun = build_rt.ocamlrun,
        .optimize = options.optimize,
    });

    const ld_conf_content = if (is_5_5_or_newer)
        "./stublibs\n.\n"
    else
        b.fmt("{s}/stublibs\n{s}\n", .{ install_libdir, install_libdir });
    const wf = b.addWriteFiles();
    const ld_conf_lp = wf.add("ld.conf", ld_conf_content);

    return .{
        .b = b,
        .ocaml_dep = self.dep,
        .src_info = self.src_info,
        .host_cfg = host_cfg,
        .target_cfg = target_cfg,
        .host_rt = host_rt,
        .target_rt = target_rt,
        .target_stdlib = target_stdlib,
        .target_compiler = target_compiler,
        .target_otherlibs = target_otherlibs,
        .ld_conf = ld_conf_lp,
    };
}

pub fn resolveTarget(b: *std.Build, ocaml_target: []const u8) std.Build.ResolvedTarget {
    return target_config.resolveTarget(b, ocaml_target);
}
