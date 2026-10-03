const Build = @import("std").Build;
const Runtime = @import("runtime.zig").Artifacts;
const Bootstrap = @import("bootstrap.zig");

pub fn artifacts(
    b: *Build,
    step: *Build.Step,
    runtime: Runtime,
    stdlib: Bootstrap.Stdlib,
    compiler: Bootstrap.Compiler,
) void {
    step.dependOn(&b.addInstallArtifact(runtime.executable, .{}).step);
    step.dependOn(&b.addInstallFile(runtime.primitive_names, "lib/ocaml/primitives").step);

    for (stdlib.names, stdlib.modules) |name, module| {
        step.dependOn(&b.addInstallFile(module.cmi, b.fmt("lib/ocaml/{s}.cmi", .{name})).step);
        step.dependOn(&b.addInstallFile(module.cmo.?, b.fmt("lib/ocaml/{s}.cmo", .{name})).step);
    }
    step.dependOn(&b.addInstallFile(stdlib.archive, "lib/ocaml/stdlib.cma").step);

    for (compiler.installed_interfaces) |interface| {
        step.dependOn(&b.addInstallFile(
            interface.path,
            b.fmt("lib/ocaml/compiler-libs/{s}.cmi", .{interface.name}),
        ).step);
    }
    step.dependOn(&b.addInstallFile(compiler.common_archive, "lib/ocaml/compiler-libs/ocamlcommon.cma").step);
    step.dependOn(&b.addInstallFile(compiler.bytecomp_archive, "lib/ocaml/compiler-libs/ocamlbytecomp.cma").step);
    step.dependOn(&b.addInstallFile(compiler.executable, "bin/ocamlc").step);
}
