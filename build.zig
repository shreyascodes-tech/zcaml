const std = @import("std");
const Ocaml = @import("build/ocaml.zig");
const Tools = @import("build/tools/root.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
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

        const host_str = b.option([]const u8, "ocaml-host", "where the ocaml compiler runs (zig/autoconf triple or `native`)") orelse {
            std.log.err("missing -Docaml-host", .{});
            return error.MissingCompilerHost;
        };
        const host = Ocaml.resolveTarget(b, host_str);
        const target = if (b.option([]const u8, "ocaml-target", "where compiled programs run (default: host)")) |s|
            Ocaml.resolveTarget(b, s)
        else
            host;

        const sub_path = b.option([]const u8, "ocaml-prefix", "install sub-path under the install prefix") orelse b.fmt(
            "{t}/host-{s}/target-{s}",
            .{ version, try host.result.linuxTriple(b.allocator), try target.result.linuxTriple(b.allocator) },
        );

        const src = ocaml_versions.source(version) orelse return;
        const toolchain = Ocaml.build(src, .{
            .host = host,
            .target = target,
            .optimize = optimize,
            .ocamldoc = b.option(bool, "ocamldoc", "build and install ocamldoc") orelse false,
            .ocamldebug = b.option(bool, "ocamldebug", "build and install ocamldebug") orelse false,
            .ocamlnat = b.option(bool, "ocamlnat", "build and install ocamlnat (native toplevel)") orelse false,
            .bytecode_tools = b.option(bool, "bytecode-tools", "install internal bytecode tools (cmpbyt, dumpobj, primreq, stripdebug)") orelse false,
            .runtime_variants = b.option(bool, "runtime-variants", "build and install debug (d) and instrumented (i) runtimes") orelse false,
        });
        toolchain.addInstall(b.getInstallStep(), sub_path);
    }
}
