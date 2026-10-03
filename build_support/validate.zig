const Build = @import("std").Build;
const Compile = Build.Step.Compile;
const Index = @import("manifest.zig").Index;
const Config = @import("config.zig").Config;
const Bootstrap = @import("bootstrap.zig");

pub fn add(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    compiler: Build.LazyPath,
    index: *const Index,
    config: Config,
) !void {
    const step = b.step(
        "validate-ocaml",
        "Rebuild the standard library using source-built ocamlc and run a bytecode program",
    );
    const version = index.data.ocaml_version;
    checkCompilerOutput(b, runtime, compiler, &.{"-version"}, b.fmt("{s}\n", .{version}), step);
    checkCompilerOutput(b, runtime, compiler, &.{ "-config-var", "native_compiler" }, "false", step);
    checkCompilerOutput(b, runtime, compiler, &.{ "-config-var", "c_compiler" }, "zig cc", step);
    checkCompilerOutput(
        b,
        runtime,
        compiler,
        &.{ "-config-var", "cmi_magic_number" },
        b.fmt("{s}I{s}", .{ index.data.magic_prefix, index.data.magic_version }),
        step,
    );
    checkCompilerOutput(b, runtime, compiler, &.{"-where"}, b.fmt("{s}\n", .{config.install_library}), step);

    const rebuilt = try Bootstrap.stdlib(b, ocaml, runtime, compiler, index);
    const source = b.addWriteFiles();
    const smoke_ml = source.add("smoke.ml", "let numbers = List.map (fun n -> n * n) [1; 2; 3] in\n" ++
        "Printf.printf \"OCaml %s: %d\\n\" Sys.ocaml_version (List.fold_left ( + ) 0 numbers)\n");
    const link = Build.Step.Run.create(b, "link source-built OCaml smoke program");
    link.addArtifactArg(runtime);
    link.addFileArg(compiler);
    link.addArgs(&.{ "-nostdlib", "-without-runtime", "-I" });
    link.addDirectoryArg(rebuilt.library_dir);
    link.addArg("-o");
    const bytecode = link.addOutputFileArg("smoke.byte");
    link.addFileArg(smoke_ml);

    const execute = Build.Step.Run.create(b, "run source-built OCaml smoke program");
    execute.addArtifactArg(runtime);
    execute.addFileArg(bytecode);
    execute.expectStdOutEqual(b.fmt("OCaml {s}: 14\n", .{version}));
    step.dependOn(&execute.step);
}

fn checkCompilerOutput(
    b: *Build,
    runtime: *Compile,
    compiler: Build.LazyPath,
    args: []const []const u8,
    expected: []const u8,
    step: *Build.Step,
) void {
    const run = Build.Step.Run.create(b, "check source-built OCaml compiler");
    run.addArtifactArg(runtime);
    run.addFileArg(compiler);
    run.addArgs(args);
    run.expectStdOutEqual(expected);
    step.dependOn(&run.step);
}
