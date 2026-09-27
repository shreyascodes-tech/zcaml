const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;

const Manifest = @import("tools/manifest.zig");
const manifest: Manifest = @import("build/gen/manifest.zon");

pub fn build(b: *Build) !void {
    const build_machine = b.graph.host;
    if (build_machine.result.cpu.arch != .x86_64 or build_machine.result.os.tag != .linux)
        @panic("the first OCaml bootstrap slice supports x86_64-linux build machines");

    const ocaml = b.dependency("ocaml", .{});

    addPrepareStep(b, ocaml);

    const primitives = loadPrimitives(b, ocaml);
    const runtime = try addOcamlrun(b, ocaml, primitives.prims_c);

    const ocaml_step = b.step("ocaml", "Bootstrap the native OCaml bytecode interpreter");
    addEnsureManifestStep(b, ocaml_step);
    ocaml_step.dependOn(&b.addInstallArtifact(runtime, .{}).step);
    ocaml_step.dependOn(&b.addInstallFile(primitives.names_file, "lib/ocaml/primitives").step);
}

fn addPrepareStep(b: *Build, ocaml: *Build.Dependency) void {
    const prepare_exe = b.addExecutable(.{
        .name = "prepare-ocaml",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/prepare.zig"),
        }),
    });

    const prepare_run = b.addRunArtifact(prepare_exe);
    prepare_run.addDirectoryArg(ocaml.path("."));
    prepare_run.addArg(@import("build.zig.zon").dependencies.ocaml.hash);
    prepare_run.addArg("build/gen/manifest.zon");
    prepare_run.setCwd(b.path("."));
    prepare_run.stdio = .inherit;

    const prepare_step = b.step("prepare", "Regenerate the checked-in OCaml source manifest");
    prepare_step.dependOn(&prepare_run.step);
}

const GeneratedPrimitives = struct {
    names_file: Build.LazyPath,
    prims_c: Build.LazyPath,
};

fn loadPrimitives(b: *Build, ocaml: *Build.Dependency) GeneratedPrimitives {
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

    return .{
        .names_file = primitives_run.addOutputFileArg("primitives"),
        .prims_c = primitives_run.addOutputFileArg("prims.c"),
    };
}

fn addOcamlrun(b: *Build, ocaml: *Build.Dependency, prims_c: Build.LazyPath) !*Compile {
    const runtime = b.addExecutable(.{
        .name = "ocamlrun",
        .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .Debug, .link_libc = true }),
    });

    runtime.root_module.addIncludePath(ocaml.path("runtime"));

    try addRuntimeHeaders(b, ocaml, runtime);

    runtime.root_module.addCMacro("CAMLDLLIMPORT", "");
    runtime.root_module.addCMacro("IN_CAML_RUNTIME", "");

    const flags: []const []const u8 = &.{ "-std=gnu11", "-fwrapv" };
    for (manifest.source_groups) |group| {
        if (Manifest.isBytecodeRuntimeGroup(group.name)) {
            runtime.root_module.addCSourceFiles(.{ .root = ocaml.path("."), .files = group.files, .flags = flags });
        }
    }

    runtime.root_module.addCSourceFile(.{ .file = prims_c, .flags = flags });
    runtime.root_module.linkSystemLibrary("m", .{});
    runtime.root_module.linkSystemLibrary("pthread", .{});
    runtime.root_module.linkSystemLibrary("dl", .{});

    return runtime;
}

fn addRuntimeHeaders(b: *Build, ocaml: *Build.Dependency, runtime: *Compile) !void {
    // This initial bootstrap configuration is for an x86_64 Linux build machine.
    const machine_header = b.addConfigHeader(.{ .include_path = "caml/m.h" }, .{
        .ARCH_SIXTYFOUR = 1,
        .SIZEOF_INT = 4,
        .SIZEOF_LONG = 8,
        .SIZEOF_PTR = 8,
        .SIZEOF_SHORT = 2,
        .SIZEOF_LONGLONG = 8,
        .HEADER_RESERVED_BITS = 0,
        .FLAT_FLOAT_ARRAY = 1,
        .NO_NAKED_POINTERS = 1,
        .CAML_SAFE_STRING = 1,
    });

    const system_header = b.addConfigHeader(.{ .include_path = "caml/s.h" }, .{
        .OCAML_OS_TYPE = "Unix",
        .POSIX_SIGNALS = 1,
        .SUPPORT_DYNAMIC_LINKING = 1,
        .HAS_FULL_THREAD_VARIABLES = 1,
        .HAS_C99_FLOAT_OPS = 1,
        .HAS_WORKING_FMA = 1,
        .HAS_WORKING_ROUND = 1,
        .HAS_GETENTROPY = 1,
        .HAS_GETRUSAGE = 1,
        .HAS_TIMES = 1,
        .HAS_SYS_MMAN_H = 1,
        .HAS_LINUX_FUTEX_H = 1,
        .HAS_POSIX_MONOTONIC_CLOCK = 1,
        .HAVE_MAX_ALIGN_T = 1,
    });

    const parsed_version = try std.SemanticVersion.parse(manifest.ocaml_version);
    const version_header = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = ocaml.path("runtime/caml/version.h.in") },
        .include_path = "caml/version.h",
    }, .{
        .OCAML_VERSION_MAJOR = @as(i64, @intCast(parsed_version.major)),
        .OCAML_VERSION_MINOR = @as(i64, @intCast(parsed_version.minor)),
        .OCAML_VERSION_PATCHLEVEL = @as(i64, @intCast(parsed_version.patch)),
        .OCAML_VERSION_ADDITIONAL = "",
        .OCAML_VERSION_EXTRA = "",
        .OCAML_VERSION = @as(i64, @intCast(parsed_version.major * 10000 + parsed_version.minor * 100 + parsed_version.patch)),
        .OCAML_VERSION_STRING = manifest.ocaml_version,
        .OCAML_RELEASE_NUMBER = @as(i64, manifest.release_number),
    });

    const exec_header = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = ocaml.path("runtime/caml/exec.h.in") },
        .include_path = "caml/exec.h",
    }, .{
        .EXEC_MAGIC_LENGTH = @as(i64, @intCast(manifest.magic_prefix.len + manifest.exec_format.len + manifest.magic_version.len)),
        .MAGIC_NUMBER_PREFIX = manifest.magic_prefix,
        .EXEC_FORMAT = manifest.exec_format,
        .MAGIC_NUMBER_VERSION = manifest.magic_version,
    });

    const build_header = b.addConfigHeader(.{ .include_path = "build_config.h" }, .{
        .OCAML_STDLIB_DIR = "",
        .HOST = "x86_64-unknown-linux-gnu",
        .BYTECODE_RUNTIME_ID = "",
    });

    inline for (&.{ machine_header, system_header, version_header, exec_header, build_header }) |header| {
        runtime.root_module.addConfigHeader(header);
        // OCaml headers include generated headers by basename (e.g. "m.h").
        runtime.root_module.addIncludePath(header.getOutputDir().path(b, "caml"));
    }
}

fn addEnsureManifestStep(b: *Build, step: *Build.Step) void {
    const hash = @import("build.zig.zon").dependencies.ocaml.hash;
    if (!std.mem.eql(u8, manifest.source_hash, hash)) {
        step.dependOn(&b.addFail("OCaml source changed: run zig build prepare and review build/gen/manifest.zon").step);
    }
}
