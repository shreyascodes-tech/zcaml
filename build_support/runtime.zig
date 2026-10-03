const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const Manifest = @import("manifest.zig").Data;
const Config = @import("config.zig").Config;

pub const Artifacts = struct {
    executable: *Compile,
    primitive_names: Build.LazyPath,
};

pub fn build(
    b: *Build,
    ocaml: *Build.Dependency,
    manifest: Manifest,
    config: Config,
) !Artifacts {
    const primitives_exe = b.addExecutable(.{
        .name = "ocaml-primitives",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/ocaml_primitives.zig"),
        }),
    });
    const primitives_run = b.addRunArtifact(primitives_exe);
    primitives_run.addFileArg(b.path("build/gen/manifest.zon"));
    primitives_run.addDirectoryArg(ocaml.path("."));
    const names = primitives_run.addOutputFileArg("primitives");
    const prims_c = primitives_run.addOutputFileArg("prims.c");

    const runtime = b.addExecutable(.{
        .name = "ocamlrun",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });
    runtime.root_module.addIncludePath(ocaml.path("runtime"));
    addHeaders(b, ocaml, runtime, manifest, config);
    runtime.root_module.addCMacro("CAMLDLLIMPORT", "");
    runtime.root_module.addCMacro("IN_CAML_RUNTIME", "");

    const flags: []const []const u8 = &.{ "-std=gnu11", "-fwrapv" };
    for (manifest.source_groups) |group| {
        if (Manifest.isBytecodeRuntimeGroup(group.name)) {
            runtime.root_module.addCSourceFiles(.{
                .root = ocaml.path("."),
                .files = group.files,
                .flags = flags,
            });
        }
    }
    runtime.root_module.addCSourceFile(.{ .file = prims_c, .flags = flags });
    runtime.root_module.linkSystemLibrary("m", .{});
    runtime.root_module.linkSystemLibrary("pthread", .{});
    runtime.root_module.linkSystemLibrary("dl", .{});

    return .{ .executable = runtime, .primitive_names = names };
}

fn addHeaders(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    manifest: Manifest,
    config: Config,
) void {
    const version = std.SemanticVersion.parse(manifest.ocaml_version) catch @panic("invalid manifest version");
    const machine = config.machineHeader(b);
    const system = config.systemHeader(b);
    const version_number = version.major * 10000 + version.minor * 100 + version.patch;
    const version_header = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = ocaml.path("runtime/caml/version.h.in") },
        .include_path = "caml/version.h",
    }, .{
        .OCAML_VERSION_MAJOR = @as(i64, @intCast(version.major)),
        .OCAML_VERSION_MINOR = @as(i64, @intCast(version.minor)),
        .OCAML_VERSION_PATCHLEVEL = @as(i64, @intCast(version.patch)),
        .OCAML_VERSION_ADDITIONAL = "",
        .OCAML_VERSION_EXTRA = "",
        .OCAML_VERSION = @as(i64, @intCast(version_number)),
        .OCAML_VERSION_STRING = manifest.ocaml_version,
        .OCAML_RELEASE_NUMBER = @as(i64, manifest.release_number),
    });
    const exec_magic_length = manifest.magic_prefix.len + manifest.exec_format.len + manifest.magic_version.len;
    const exec_header = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = ocaml.path("runtime/caml/exec.h.in") },
        .include_path = "caml/exec.h",
    }, .{
        .EXEC_MAGIC_LENGTH = @as(i64, @intCast(exec_magic_length)),
        .MAGIC_NUMBER_PREFIX = manifest.magic_prefix,
        .EXEC_FORMAT = manifest.exec_format,
        .MAGIC_NUMBER_VERSION = manifest.magic_version,
    });
    const build_header = b.addConfigHeader(.{ .include_path = "build_config.h" }, .{
        .OCAML_STDLIB_DIR = "",
        .HOST = config.profile.host_triple,
        .BYTECODE_RUNTIME_ID = "",
    });

    const headers = .{ machine, system, version_header, exec_header, build_header };
    inline for (&headers) |header| {
        runtime.root_module.addConfigHeader(header);
        runtime.root_module.addIncludePath(header.getOutputDir().path(b, "caml"));
    }
}
