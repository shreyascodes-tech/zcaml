const std = @import("std");
const Build = std.Build;
const Io = std.Io;

const Manifest = @import("build_support/manifest.zig");
const Config = @import("build_support/config.zig").Config;
const Runtime = @import("build_support/runtime.zig");
const Bootstrap = @import("build_support/bootstrap.zig");
const Install = @import("build_support/install.zig");
const Validate = @import("build_support/validate.zig");

pub fn build(b: *Build) !void {
    const ocaml = b.dependency("ocaml", .{});
    addPrepareStep(b, ocaml);

    const step = b.step("ocaml", "Bootstrap OCaml interpreter, standard library, and compiler");
    const config = Config.native(b);
    if (!config.supported()) {
        step.dependOn(&b.addFail("the OCaml runtime bootstrap requires an x86_64-linux build machine").step);
        return;
    }

    // Read at graph construction time: prepare also works without a manifest.
    const text = Io.Dir.cwd().readFileAllocOptions(
        b.graph.io,
        "build/gen/manifest.zon",
        b.allocator,
        .unlimited,
        .of(u8),
        0,
    ) catch {
        const failure = b.addFail("OCaml source manifest missing: run zig build prepare and review build/gen/manifest.zon");
        step.dependOn(&failure.step);
        return;
    };
    const data = std.zon.parse.fromSliceAlloc(Manifest.Data, b.allocator, text, null, .{}) catch {
        const failure = b.addFail("OCaml source manifest invalid: run zig build prepare and review build/gen/manifest.zon");
        step.dependOn(&failure.step);
        return;
    };
    if (!std.mem.eql(u8, data.source_hash, @import("build.zig.zon").dependencies.ocaml.hash)) {
        const failure = b.addFail("OCaml source changed: run zig build prepare and review build/gen/manifest.zon");
        step.dependOn(&failure.step);
        return;
    }
    _ = std.SemanticVersion.parse(data.ocaml_version) catch {
        const failure = b.addFail("OCaml manifest has an invalid runtime version: run zig build prepare and review build/gen/manifest.zon");
        step.dependOn(&failure.step);
        return;
    };

    const index = Manifest.Index.init(b, data) catch |err| {
        step.dependOn(&b.addFail(b.fmt("invalid OCaml manifest index: {s}", .{@errorName(err)})).step);
        return;
    };
    const runtime = try Runtime.build(b, ocaml, data, config);
    const stdlib = Bootstrap.stdlib(
        b,
        ocaml,
        runtime.executable,
        ocaml.path("boot/ocamlc"),
        &index,
    ) catch |err| {
        step.dependOn(&b.addFail(b.fmt("OCaml stdlib graph: {s}", .{@errorName(err)})).step);
        return;
    };
    const compiler = Bootstrap.compiler(
        b,
        ocaml,
        runtime.executable,
        runtime.primitive_names,
        stdlib,
        &index,
        config,
    ) catch |err| {
        step.dependOn(&b.addFail(b.fmt("OCaml compiler graph: {s}", .{@errorName(err)})).step);
        return;
    };
    Install.artifacts(b, step, runtime, stdlib, compiler);
    Validate.add(b, ocaml, runtime.executable, compiler.executable, &index, config) catch |err| {
        step.dependOn(&b.addFail(b.fmt("OCaml validation graph: {s}", .{@errorName(err)})).step);
    };
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
    const run = b.addRunArtifact(prepare_exe);
    run.addDirectoryArg(ocaml.path("."));
    run.addArg(@import("build.zig.zon").dependencies.ocaml.hash);
    run.addArg("build/gen/manifest.zon");
    run.setCwd(b.path("."));
    run.stdio = .inherit;

    const step = b.step("prepare", "Regenerate the checked-in OCaml source manifest");
    step.dependOn(&run.step);
}
