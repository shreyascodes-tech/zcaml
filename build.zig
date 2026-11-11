const std = @import("std");
const Ocaml = @import("build/ocaml/ocaml.zig");
const Platform = @import("build/ocaml/platform.zig");
const Tools = @import("build/ocaml/tools.zig");
const Dune = @import("build/dune/dune.zig");

pub fn build(b: *std.Build) !void {
    const check_step = b.step("check", "compile the build's Zig programs, without installing them (for ZLS)");
    Ocaml.addCheck(b, check_step);
    Dune.addCheck(b, check_step);
    check_step.dependOn(&buildPkgConfig(b, .init(b, Ocaml.resolveTarget(b, "native"))).step);

    const gen_step = b.step("generate", "generate OCaml version manifests from upstream Makefiles");
    const update_src = b.addUpdateSourceFiles();
    for (Ocaml.Versions.all) |ver| {
        const dep = Ocaml.Versions.dependency(b, ver) orelse continue;
        const gen, _ = Tools.run(b, .gen_manifests, .{
            .ocaml_src_dir = .of(dep.path("")),
            .out_file = .of(std.fs.path.basename(Ocaml.Versions.manifestPath(ver))),
        });
        update_src.addCopyFileToSource(gen.out_file.lazyPath(), Ocaml.Versions.manifestPath(ver));
    }
    gen_step.dependOn(&update_src.step);

    // For `ZCAML_MACOS_SDK`: cross-compiling C for macOS outside this build (dune
    // pkg's packages).
    if (b.option(bool, "macos-sdk", "install the macOS SDK, in Xcode's layout, to zig-out/macos-sdk") orelse false) {
        if (b.lazyDependency("xcode_frameworks", .{})) |dep| {
            b.installDirectory(.{ .source_dir = Ocaml.MacosSdk.layout(b, dep), .install_dir = .prefix, .install_subdir = "macos-sdk" });
        }
    }

    if (b.option(bool, "ocaml", "build ocaml") orelse false) {
        const version = b.option(Ocaml.Version, "ocaml-version", "ocaml version to build") orelse Ocaml.Versions.latest;
        const ocamldoc_opt = b.option(bool, "ocamldoc", "build and install ocamldoc");
        const ocamldebug_opt = b.option(bool, "ocamldebug", "build and install ocamldebug");
        const ocamlnat_opt = b.option(bool, "ocamlnat", "build and install ocamlnat (native toplevel)");
        const bytecode_tools_opt = b.option(bool, "bytecode-tools", "install internal bytecode tools (cmpbyt, dumpobj, primreq, stripdebug)");
        const runtime_variants_opt = b.option(bool, "runtime-variants", "build and install debug (d) and instrumented (i) runtimes");

        const host_opt = b.option([]const u8, "ocaml-host", "where the ocaml compiler runs (zig/autoconf triple or `native`)");
        const target_opt = b.option([]const u8, "ocaml-target", "where compiled programs run (default: host)");
        const jobs_opt = b.option(usize, "verify-jobs", "number of parallel verification workers") orelse 8;
        const save_deferred_opt = b.option([]const u8, "save-deferred", "directory to save cross-OS target execution bundles");
        const run_deferred_opt = b.option([]const u8, "run-deferred", "directory of deferred bundles to execute on this OS");

        const verify_step = b.step("verify", "verify built OCaml toolchains in zig-out/");
        const root_dir_opt = b.option([]const u8, "verify-root", "path to zig-out/<version> directory");
        const root_dir_str = root_dir_opt orelse b.fmt("zig-out/{t}", .{version});
        _, const run_verify = Tools.run(b, .verify_toolchains, .{
            .root_dir = root_dir_str,
            .fixtures_dir = .of(b.path("test/fixtures")),
            .host = host_opt,
            .target = target_opt,
            .jobs = jobs_opt,
            .save_deferred = save_deferred_opt,
            .run_deferred = run_deferred_opt,
        });
        run_verify.stdio = .inherit;
        verify_step.dependOn(&run_verify.step);

        const dune_step = b.step("dune", "bootstrap dune for the build machine and every -Ddune-target");
        const dune_targets = b.option([]const []const u8, "dune-target", "target to bootstrap dune for (repeatable; default: -Docaml-target)");
        const dune_toolchains = b.option([]const u8, "dune-toolchains", "bootstrap dune with the toolchains installed in this zig-out/<version> directory, instead of building them");
        if (dune_toolchains) |root| {
            const dep = b.lazyDependency("dune", .{}) orelse return;
            const macos_sdk = duneMacosSdk(b, dune_targets orelse &.{}) catch return;
            addDune(b, dune_step, .init(b, dep, macos_sdk), .{ .installed = root }, dune_targets orelse &.{});
            return;
        }

        // Skip instantiating the OCaml build graph when running `verify` against prebuilt toolchains.
        if (root_dir_opt != null or run_deferred_opt != null or save_deferred_opt != null or
            b.user_input_options.contains("verify-jobs"))
        {
            return;
        }

        const matrix_step = b.step("matrix", "build and install the full host -> target compiler matrix");
        // Request every lazy dependency before bailing out, so zig fetches them all in one pass.
        const ocaml_dep = Ocaml.Versions.dependency(b, version);
        const flexdll = b.lazyDependency("flexdll", .{});
        const zstd_fetched = b.lazyDependency("zstd", .{}) != null;
        const dune_dep = b.lazyDependency("dune", .{});
        if (ocaml_dep == null or flexdll == null or !zstd_fetched or dune_dep == null) return;
        const src = Ocaml.Versions.source(b, version, .{ .flexdll = flexdll.?, .zstd = zstdDependency }).?;

        const default_extra = host_opt == null;
        var ocaml: Ocaml = .init(src, .{
            .ocamldoc = ocamldoc_opt orelse default_extra,
            .ocamldebug = ocamldebug_opt orelse default_extra,
            .ocamlnat = ocamlnat_opt orelse default_extra,
            .bytecode_tools = bytecode_tools_opt orelse default_extra,
            .runtime_variants = runtime_variants_opt orelse default_extra,
        });

        if (host_opt) |host_str| {
            const host = Ocaml.resolveTarget(b, host_str);
            const target = if (target_opt) |s|
                Ocaml.resolveTarget(b, s)
            else
                host;

            const sub_path = b.option([]const u8, "ocaml-prefix", "install sub-path under the install prefix") orelse
                defaultSubPath(b, version, host, target);

            const toolchain = ocaml.build(host, target);
            toolchain.addInstall(b.getInstallStep(), sub_path);
            addBinutilsInstall(b, b.getInstallStep(), toolchain, sub_path);
            addPkgConfigInstall(b, b.getInstallStep(), toolchain, sub_path);

            const targets: []const []const u8 = dune_targets orelse if (target_opt) |t| &.{t} else &.{};
            const macos_sdk = duneMacosSdk(b, targets) catch return;
            addDune(b, dune_step, .init(b, dune_dep.?, macos_sdk), .{ .built = &ocaml }, targets);
        } else {
            b.getInstallStep().dependOn(&b.addFail("missing -Docaml-host (or run `zig build -Docaml matrix`)").step);
            dune_step.dependOn(&b.addFail("missing -Docaml-host=native or -Ddune-toolchains").step);
            for (matrix_pairs) |pair| {
                const host = Ocaml.resolveTarget(b, pair.host);
                const target = Ocaml.resolveTarget(b, pair.target);
                const tc = ocaml.build(host, target);
                const sub_path = defaultSubPath(b, version, host, target);
                tc.addInstall(matrix_step, sub_path);
                addBinutilsInstall(b, matrix_step, tc, sub_path);
                addPkgConfigInstall(b, matrix_step, tc, sub_path);
            }
        }
        return;
    }
}

/// Dune for every `targets` (and the build machine), bootstrapped with the native
/// toolchain and the target's, installed to `dune/<target>/bin/`.
fn addDune(b: *std.Build, step: *std.Build.Step, dune: Dune, toolchains: DuneToolchains, targets: []const []const u8) void {
    const native = Ocaml.resolveTarget(b, "native");
    const native_tc = toolchains.get(b, native, native);
    const native_name = native.result.linuxTriple(b.allocator) catch @panic("OOM");
    installDune(b, step, dune, native_tc, native_tc, native_name, native);
    for (targets) |t| {
        const target = Ocaml.resolveTarget(b, t);
        const name = target.result.linuxTriple(b.allocator) catch @panic("OOM");
        if (std.mem.eql(u8, name, native_name)) continue;
        installDune(b, step, dune, native_tc, toolchains.get(b, native, target), name, target);
    }
}

/// The macOS SDK, if dune is bootstrapped for macOS (the build machine or `targets`).
/// `error.Fetching` until Zig has fetched it and rerun the build script.
fn duneMacosSdk(b: *std.Build, targets: []const []const u8) error{Fetching}!?std.Build.LazyPath {
    const macos = for (targets) |t| {
        if (Ocaml.resolveTarget(b, t).result.os.tag == .macos) break true;
    } else b.graph.host.result.os.tag == .macos;
    if (!macos) return null;
    const dep = b.lazyDependency("xcode_frameworks", .{}) orelse return error.Fetching;
    return Ocaml.MacosSdk.layout(b, dep);
}

/// Where `addDune` gets its toolchains: built here, or installed (`zig-out/<version>`).
const DuneToolchains = union(enum) {
    built: *Ocaml,
    installed: []const u8,

    fn get(self: DuneToolchains, b: *std.Build, host: std.Build.ResolvedTarget, target: std.Build.ResolvedTarget) std.Build.LazyPath {
        return switch (self) {
            .built => |ocaml| ocaml.build(host, target).directory(),
            .installed => |root| .{ .cwd_relative = b.fmt("{s}/host-{s}/target-{s}", .{
                root,
                host.result.linuxTriple(b.allocator) catch @panic("OOM"),
                target.result.linuxTriple(b.allocator) catch @panic("OOM"),
            }) },
        };
    }
};

fn installDune(b: *std.Build, step: *std.Build.Step, dune: Dune, native_tc: std.Build.LazyPath, tc: std.Build.LazyPath, name: []const u8, target: std.Build.ResolvedTarget) void {
    const exe = dune.bootstrap(native_tc, tc, target);
    const dest = b.fmt("dune/{s}/bin/dune{s}", .{ name, if (target.result.os.tag == .windows) ".exe" else "" });
    step.dependOn(&b.addInstallFileWithDir(exe, .prefix, dest).step);
}

/// The rest of `cc_wrapper.zig`'s `binutils` multicall; `Toolchain.layout` installs
/// `ar` and `ranlib` itself. All of them run on the host and take no target flags.
/// `strip` and `objdump` are left out until Zig 0.17 can implement them: its
/// `objcopy` has no ELF->ELF mode and its `objdump` is still a stub, so installing
/// them would shadow working host tools with broken ones.
const binutils_tools = [_][]const u8{ "objcopy", "dlltool", "lib", "rc" };

/// Install the host's binutils wrapper as the plain tool names and as
/// `zcaml-<tool>-<target>`, beside `ar` and `ranlib`.
fn addBinutilsInstall(b: *std.Build, step: *std.Build.Step, tc: Ocaml.Toolchain, sub_path: []const u8) void {
    const exe = tc.binutils.getEmittedBin();
    const host_exe = tc.host_rt.platform.exeExt();
    const target = tc.target_rt.platform.triplet;
    for (binutils_tools) |tool| {
        step.dependOn(&b.addInstallFileWithDir(exe, .prefix, b.fmt("{s}/bin/{s}{s}", .{ sub_path, tool, host_exe })).step);
        step.dependOn(&b.addInstallFileWithDir(exe, .prefix, b.fmt("{s}/bin/zcaml-{s}-{s}{s}", .{ sub_path, tool, target, host_exe })).step);
    }
}

var pkg_configs: std.StringHashMapUnmanaged(*std.Build.Step.Compile) = .empty;

/// The patched u-config (`vendor/u-config`) for `host` to run. Its OCAMLPATH
/// change searches `<entry>/<name>/pkgconfig` when `PKG_CONFIG_LIBDIR` is unset,
/// which is where dune pkg's dependencies install their `.pc` files.
fn buildPkgConfig(b: *std.Build, host: Platform) *std.Build.Step.Compile {
    if (pkg_configs.get(host.triplet)) |exe| return exe;
    const windows = host.is_windows;
    const mod = b.createModule(.{
        .target = host.resolved,
        .optimize = .ReleaseSmall,
        .link_libc = !windows,
        .strip = true,
        // As upstream's mingw recipe: no unwind tables in the no-CRT image.
        .unwind_tables = if (windows) .none else null,
    });
    mod.addCSourceFile(.{
        .file = b.path(if (windows) "vendor/u-config/main_windows.c" else "vendor/u-config/main_posix.c"),
        .flags = if (windows) &.{
            // dune's `<lib>/<package>/pkgconfig` is one level deeper than
            // --define-prefix assumes.
            "-DPKG_CONFIG_DEFINE_PREFIX=0",
            "-fno-builtin",
        } else &.{},
    });
    const exe = b.addExecutable(.{ .name = "pkg-config", .root_module = mod });
    if (windows) {
        // No CRT: upstream's entry point, kernel32 only, and compiler-rt's
        // memset/memcpy plus the vendored wcslen. Zig-only, no system mingw.
        mod.addCSourceFile(.{ .file = b.path("vendor/u-config/win32_shim.c"), .flags = &.{} });
        mod.linkSystemLibrary("kernel32", .{});
        exe.entry = .{ .symbol_name = "mainCRTStartup" };
        exe.link_gc_sections = true;
    }
    pkg_configs.put(b.allocator, host.triplet, exe) catch @panic("OOM");
    return exe;
}

/// Install the host's `pkg-config` and `pkg-config-zcaml`, beside `ar` and
/// `ranlib`. A copy of one binary, as for the binutils wrappers.
fn addPkgConfigInstall(b: *std.Build, step: *std.Build.Step, tc: Ocaml.Toolchain, sub_path: []const u8) void {
    const exe = buildPkgConfig(b, tc.host_rt.platform).getEmittedBin();
    const host_exe = tc.host_rt.platform.exeExt();
    step.dependOn(&b.addInstallFileWithDir(exe, .prefix, b.fmt("{s}/bin/pkg-config{s}", .{ sub_path, host_exe })).step);
    step.dependOn(&b.addInstallFileWithDir(exe, .prefix, b.fmt("{s}/bin/pkg-config-zcaml{s}", .{ sub_path, host_exe })).step);
}

/// `zstd` is configured per target, so the OCaml build gets it as a function.
fn zstdDependency(b: *std.Build, options: Ocaml.Deps.ZstdOptions) *std.Build.Dependency {
    return b.dependency("zstd", .{ .target = options.target, .optimize = options.optimize, .pie = options.pie });
}

fn defaultSubPath(b: *std.Build, version: Ocaml.Version, host: std.Build.ResolvedTarget, target: std.Build.ResolvedTarget) []const u8 {
    return b.fmt(
        "{t}/host-{s}/target-{s}",
        .{
            version,
            host.result.linuxTriple(b.allocator) catch @panic("OOM"),
            target.result.linuxTriple(b.allocator) catch @panic("OOM"),
        },
    );
}

const Pair = struct {
    host: []const u8,
    target: []const u8,
};

const all_targets = [_][]const u8{
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

/// Static list of `(host, target)` pairs built by `zig build -Docaml matrix`.
const matrix_pairs = blk: {
    var pairs: []const Pair = &.{};
    for (all_targets) |t| {
        pairs = pairs ++ .{Pair{ .host = t, .target = t }};
    }
    // Common hosts target everything; the others are self-hosted only.
    for ([_][]const u8{
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "aarch64-macos",
        "x86_64-macos",
        "x86_64-windows-gnu",
    }) |h| {
        for (all_targets) |t| {
            if (!std.mem.eql(u8, t, h)) pairs = pairs ++ .{Pair{ .host = h, .target = t }};
        }
    }
    break :blk pairs;
};
