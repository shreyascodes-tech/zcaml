//! Bytecode compiler invocations with explicit inputs and cached outputs.

const std = @import("std");
const LazyPath = std.Build.LazyPath;
const Run = std.Build.Step.Run;

const OCamlCompile = @This();

interpreter: *std.Build.Step.Compile,
compiler: LazyPath,

pub const CompileOptions = struct {
    source: LazyPath,
    output_name: []const u8,
    includes: []const LazyPath = &.{},
    interfaces: []const LazyPath = &.{},
    interface_source: ?LazyPath = null,
    flags: []const []const u8 = &.{},
};

pub fn compile(c: OCamlCompile, b: *std.Build, o: CompileOptions) LazyPath {
    const run = c.invocation(b);
    run.addArgs(o.flags);

    // Also track the sibling .mli consulted when compiling an .ml.
    addIncludes(run, &.{o.source.dirname()});
    if (o.interface_source) |source| run.addFileInput(source);

    addIncludes(run, o.includes);
    for (o.interfaces) |cmi| {
        run.addFileInput(cmi);
        addIncludes(run, &.{cmi.dirname()});
    }

    run.addArg("-o");
    const output = run.addOutputFileArg(o.output_name);
    run.addArg("-c");
    run.addFileArg(o.source);

    return output;
}

pub fn archive(c: OCamlCompile, b: *std.Build, output_name: []const u8, objects: []const LazyPath) LazyPath {
    const run = c.invocation(b);
    run.addArgs(&.{ "-a", "-o" });
    const output = run.addOutputFileArg(output_name);

    for (objects) |object| run.addFileArg(object);

    return output;
}

pub fn invocation(c: OCamlCompile, b: *std.Build) *Run {
    const run = b.addRunArtifact(c.interpreter);
    run.addFileArg(c.compiler);

    // Never pick up a system OCaml installation or OCAMLPARAM overrides.
    run.setEnvironmentVariable("OCAMLPARAM", "");
    run.setEnvironmentVariable("OCAMLLIB", "");
    run.setEnvironmentVariable("CAMLLIB", "");

    run.addArg("-nostdlib");

    return run;
}

pub fn addIncludes(run: *Run, includes: []const LazyPath) void {
    for (includes) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
}
