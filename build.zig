const std = @import("std");
const Ocaml = @import("build/ocaml/ocaml.zig");
const Tools = @import("build/ocaml/tools.zig");
const Dune = @import("build/dune/dune.zig");

pub fn build(b: *std.Build) !void {
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

        // Skip instantiating the OCaml build graph when running `verify` against prebuilt toolchains.
        if (root_dir_opt != null or run_deferred_opt != null or save_deferred_opt != null or
            b.user_input_options.contains("verify-jobs"))
        {
            return;
        }

        const matrix_step = b.step("matrix", "build and install the full host -> target compiler matrix");
        const dune_step = b.step("dune", "bootstrap dune for the build machine and every -Ddune-target");
        const dune_targets = b.option([]const []const u8, "dune-target", "target to bootstrap dune for (repeatable; default: -Docaml-target)");
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

            const targets: []const []const u8 = dune_targets orelse if (target_opt) |t| &.{t} else &.{};
            addDune(b, dune_step, &ocaml, .init(b, dune_dep.?), targets);
        } else {
            b.getInstallStep().dependOn(&b.addFail("missing -Docaml-host (or run `zig build -Docaml matrix`)").step);
            dune_step.dependOn(&b.addFail("missing -Docaml-host=native").step);
            for (matrix_pairs) |pair| {
                const host = Ocaml.resolveTarget(b, pair.host);
                const target = Ocaml.resolveTarget(b, pair.target);
                const tc = ocaml.build(host, target);
                tc.addInstall(matrix_step, defaultSubPath(b, version, host, target));
            }
        }
        return;
    }

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
}

/// Dune for every `targets` (and the build machine), bootstrapped with the native
/// toolchain and the target's, installed to `dune/<target>/bin/`.
fn addDune(b: *std.Build, step: *std.Build.Step, ocaml: *Ocaml, dune: Dune, targets: []const []const u8) void {
    const native = Ocaml.resolveTarget(b, "native");
    const native_tc = ocaml.build(native, native).directory();
    const native_name = native.result.linuxTriple(b.allocator) catch @panic("OOM");
    installDune(b, step, dune, native_tc, native_tc, native_name, native.result.os.tag == .windows);
    for (targets) |t| {
        const target = Ocaml.resolveTarget(b, t);
        const name = target.result.linuxTriple(b.allocator) catch @panic("OOM");
        if (std.mem.eql(u8, name, native_name)) continue;
        installDune(b, step, dune, native_tc, ocaml.build(native, target).directory(), name, target.result.os.tag == .windows);
    }
}

fn installDune(b: *std.Build, step: *std.Build.Step, dune: Dune, native_tc: std.Build.LazyPath, tc: std.Build.LazyPath, name: []const u8, is_windows: bool) void {
    const exe = dune.bootstrap(native_tc, tc, is_windows);
    const dest = b.fmt("dune/{s}/bin/dune{s}", .{ name, if (is_windows) ".exe" else "" });
    step.dependOn(&b.addInstallFileWithDir(exe, .prefix, dest).step);
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
