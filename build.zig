const std = @import("std");
const Ocaml = @import("build/ocaml.zig");
const Tools = @import("build/tools.zig");

pub fn build(b: *std.Build) !void {
    const ocaml_versions: Ocaml.Versions = .init(b);

    // zig build generate: (re)generate build/manifests/*.zon from the upstream sources
    const gen_step = b.step("generate", "generate OCaml version manifests from upstream Makefiles");
    const update_src = b.addUpdateSourceFiles();
    for (Ocaml.Versions.all) |ver| {
        const dep = ocaml_versions.dependency(ver) orelse continue;
        const gen, _ = Tools.run(b, .gen_manifests, .{
            .ocaml_src_dir = .of(dep.path("")),
            .out_file = .of(std.fs.path.basename(Ocaml.Versions.manifestPath(ver))),
        });
        update_src.addCopyFileToSource(gen.out_file.lazyPath(), Ocaml.Versions.manifestPath(ver));
    }
    gen_step.dependOn(&update_src.step);

    if (b.option(bool, "ocaml", "build ocaml") orelse false) {
        const version = b.option(Ocaml.Version, "ocaml-version", "ocaml version to build") orelse Ocaml.Versions.latest;
        const ocamldoc_opt = b.option(bool, "ocamldoc", "build and install ocamldoc");
        const ocamldebug_opt = b.option(bool, "ocamldebug", "build and install ocamldebug");
        const ocamlnat_opt = b.option(bool, "ocamlnat", "build and install ocamlnat (native toplevel)");
        const bytecode_tools_opt = b.option(bool, "bytecode-tools", "install internal bytecode tools (cmpbyt, dumpobj, primreq, stripdebug)");
        const runtime_variants_opt = b.option(bool, "runtime-variants", "build and install debug (d) and instrumented (i) runtimes");

        const matrix_step = b.step("matrix", "build and install the full host -> target compiler matrix");
        const src = ocaml_versions.source(version) orelse return;

        if (b.option([]const u8, "ocaml-host", "where the ocaml compiler runs (zig/autoconf triple or `native`)")) |host_str| {
            const host = Ocaml.resolveTarget(b, host_str);
            const target = if (b.option([]const u8, "ocaml-target", "where compiled programs run (default: host)")) |s|
                Ocaml.resolveTarget(b, s)
            else
                host;

            const sub_path = b.option([]const u8, "ocaml-prefix", "install sub-path under the install prefix") orelse b.fmt(
                "{t}/host-{s}/target-{s}",
                .{ version, try host.result.linuxTriple(b.allocator), try target.result.linuxTriple(b.allocator) },
            );

            var ocaml: Ocaml = .init(src, .{
                .ocamldoc = ocamldoc_opt orelse false,
                .ocamldebug = ocamldebug_opt orelse false,
                .ocamlnat = ocamlnat_opt orelse false,
                .bytecode_tools = bytecode_tools_opt orelse false,
                .runtime_variants = runtime_variants_opt orelse false,
            });
            const toolchain = ocaml.build(host, target);
            toolchain.addInstall(b.getInstallStep(), sub_path);
        } else {
            b.getInstallStep().dependOn(&b.addFail("missing -Docaml-host (or run `zig build -Docaml matrix`)").step);
            var ocaml: Ocaml = .init(src, .{
                .ocamldoc = ocamldoc_opt orelse true,
                .ocamldebug = ocamldebug_opt orelse true,
                .ocamlnat = ocamlnat_opt orelse true,
                .bytecode_tools = bytecode_tools_opt orelse true,
                .runtime_variants = runtime_variants_opt orelse true,
            });
            for (matrix_pairs) |pair| {
                const host = Ocaml.resolveTarget(b, pair.host);
                const target = Ocaml.resolveTarget(b, pair.target);
                const tc = ocaml.build(host, target);
                const sub_path = b.fmt(
                    "{t}/host-{s}/target-{s}",
                    .{ version, try host.result.linuxTriple(b.allocator), try target.result.linuxTriple(b.allocator) },
                );
                tc.addInstall(matrix_step, sub_path);
            }
        }
    }
}

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

/// Static list of `(host, target)` pairs built by `zig build -Docaml matrix`.
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
