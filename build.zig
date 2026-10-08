const std = @import("std");
const OCamlBuild = @import("build/root.zig");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const compiler_host = b.standardTargetOptions(.{});
    const compiler_target = blk: {
        const triple = b.option([]const u8, "compiler-target", "Target triple of the output of the compiler") orelse
            break :blk compiler_host;
        break :blk b.resolveTargetQuery(try std.Build.parseTargetQuery(.{
            .arch_os_abi = triple,
        }));
    };

    // Normally the build machine, but overridable so that a cross-built
    // `ocamlrun` can be run under an emulator.
    const build_machine = blk: {
        const triple = b.option([]const u8, "build-machine", "Where the bytecode interpreter runs") orelse
            break :blk null;
        break :blk b.resolveTargetQuery(try std.Build.parseTargetQuery(.{
            .arch_os_abi = triple,
        }));
    };

    const ocaml_dep = b.dependency("ocaml", .{});
    var ocaml_build = OCamlBuild.init(b, ocaml_dep);

    try ocaml_build.build(.{
        .compiler_host = compiler_host,
        .compiler_target = compiler_target,
        .optimize = optimize,
        .build_machine = build_machine,
    });
}
