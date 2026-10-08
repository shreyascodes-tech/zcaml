// Bumping OCaml: update the hash in build.zig.zon, run `zig build gen`, review
// the diff of build/gen/sources.g.zon.

const std = @import("std");
const OCaml = @import("build/OCaml.zig");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const host = b.standardTargetOptions(.{});
    const target = try optionalTarget(b, "compiler-target", "Target triple of the output of the compiler") orelse host;
    const build_machine = try optionalTarget(b, "build-machine", "Where the bytecode interpreter runs") orelse b.graph.host;

    var ocaml: OCaml = .init(b, .{
        .dep = b.dependency("ocaml", .{}),
        .hash = manifest.dependencies.ocaml.hash,
        .toolchain = zigToolchain(b, target),
    });

    ocaml.addGenStep(b.step("gen", "Regenerate build/gen/sources.g.zon from the OCaml tree"));

    const install = b.getInstallStep();
    const out = ocaml.build(install, .{
        .host = host,
        .target = target,
        .build_machine = build_machine,
        .optimize = optimize,
    }) catch |err| switch (err) {
        error.SourcesUnavailable => return,
        else => |e| return e,
    };
    out.addInstall(install, OCaml.plainTriple(b, host));
}

/// Uses the plain `arch-os-abi` triple so that neither `native` nor the
/// build machine's kernel/libc versions end up in `config.ml`.
fn zigToolchain(b: *std.Build, target: std.Build.ResolvedTarget) OCaml.Toolchain {
    return .{
        .cc = b.fmt("zig cc -target {s}", .{OCaml.plainTriple(b, target)}),
        .ar = "zig ar",
    };
}

fn optionalTarget(b: *std.Build, name: []const u8, description: []const u8) !?std.Build.ResolvedTarget {
    const triple = b.option([]const u8, name, description) orelse return null;
    const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
        std.log.err("-D{s}={s}: {t}", .{ name, triple, err });
        return err;
    };
    return b.resolveTargetQuery(query);
}
