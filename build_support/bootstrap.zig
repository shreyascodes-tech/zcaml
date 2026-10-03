const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const Index = @import("manifest.zig").Index;
const Config = @import("config.zig").Config;
const ocaml_build = @import("ocaml.zig");
const Sources = @import("sources.zig").Sources;

pub const Stdlib = struct {
    library_dir: Build.LazyPath,
    archive: Build.LazyPath,
    exit_object: Build.LazyPath,
    modules: []const ocaml_build.Module,
    names: []const []const u8,
};

pub const Compiler = struct {
    executable: Build.LazyPath,
    common_archive: Build.LazyPath,
    bytecomp_archive: Build.LazyPath,
    installed_interfaces: []const Interface,
};

pub const Interface = struct {
    name: []const u8,
    path: Build.LazyPath,
};

pub fn stdlib(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    compiler_path: Build.LazyPath,
    index: *const Index,
) !Stdlib {
    const source_exe = b.addExecutable(.{
        .name = "stdlib-source",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/stdlib_source.zig"),
        }),
    });
    var engine = ocaml_build.Engine.init(b, runtime, compiler_path, index, null);
    const modules = index.data.stdlib_modules;
    const specs = try b.allocator.alloc(ocaml_build.Spec, modules.len);
    const names = try b.allocator.alloc([]const u8, modules.len);
    const built = try b.allocator.alloc(ocaml_build.Module, modules.len);

    for (modules, 0..) |module, i| {
        const stem = b.fmt("stdlib/{s}", .{module.output});
        const interface = stdlibSource(
            b,
            ocaml,
            source_exe,
            module.interface,
            module.expand_interface_aliases,
        );
        const implementation = stdlibSource(
            b,
            ocaml,
            source_exe,
            module.source,
            module.expand_implementation_aliases,
        );
        specs[i] = .{
            .stem = stem,
            .name = module.output,
            .interface = interface,
            .implementation = implementation,
            .interface_flags = module.interface_flags,
            .implementation_flags = module.implementation_flags,
        };
        names[i] = module.output;
        try engine.add(specs[i]);
    }
    try engine.wire(specs);

    const archive = try engine.archive("stdlib");

    const library = b.addWriteFiles();
    for (names, built, 0..) |name, *item, i| {
        item.* = engine.modules.get(specs[i].stem).?;
        _ = library.addCopyFile(item.cmi, b.fmt("{s}.cmi", .{name}));
    }
    const exit_name = "std_exit";
    var exit_declared = false;
    for (modules) |definition| {
        if (!std.mem.eql(u8, definition.output, exit_name)) continue;
        if (definition.archive_member or exit_declared) {
            std.log.err("stdlib exit module must be unique and outside the archive: {s}", .{exit_name});
            return error.InvalidExitModule;
        }
        exit_declared = true;
    }
    if (!exit_declared) {
        std.log.err("missing stdlib exit module in manifest: {s}", .{exit_name});
        return error.MissingExitModule;
    }

    const exit_module = engine.modules.get("stdlib/std_exit") orelse return error.MissingExitModule;
    const exit = exit_module.cmo orelse return error.MissingExitModule;
    _ = library.addCopyFile(exit, "std_exit.cmo");
    _ = library.addCopyFile(archive, "stdlib.cma");

    return .{
        .library_dir = library.getDirectory(),
        .archive = archive,
        .exit_object = exit,
        .modules = built,
        .names = names,
    };
}

pub fn compiler(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    primitives: Build.LazyPath,
    stdlib_artifacts: Stdlib,
    index: *const Index,
    config: Config,
) !Compiler {
    const boot_compiler = ocaml.path("boot/ocamlc");
    var sources = Sources.init(b, ocaml, runtime, primitives, index, config);
    var engine = ocaml_build.Engine.init(b, runtime, boot_compiler, index, stdlib_artifacts.library_dir);
    const modules = index.data.compiler_modules;
    const specs = try b.allocator.alloc(ocaml_build.Spec, modules.len);
    var installed: std.ArrayList(Interface) = .empty;

    for (modules, 0..) |module, i| {
        const source = if (module.implementation) |path| try sources.resolve(path) else null;
        const interface = if (module.interface) |path| try sources.resolve(path) else null;
        specs[i] = .{
            .stem = module.stem,
            .name = std.fs.path.basename(module.stem),
            .interface = interface,
            .implementation = source,
        };
        try engine.add(specs[i]);
    }
    try engine.wire(specs);

    for (modules) |module| {
        if (!module.install_interface) continue;
        const built = engine.modules.get(module.stem).?;
        try installed.append(b.allocator, .{
            .name = std.fs.path.basename(module.stem),
            .path = built.cmi,
        });
    }

    const common = try engine.archive("ocamlcommon");
    const bytecomp = try engine.archive("ocamlbytecomp");
    const link = ocaml_build.compilerRun(b, runtime, boot_compiler);
    link.addArgs(&.{ "-compat-32", "-g", "-without-runtime", "-set-runtime-default" });
    link.addArg(b.fmt("standard_library_default={s}", .{config.install_library}));
    link.addArg("-o");
    const executable = link.addOutputFileArg("ocamlc");
    link.addArg("-I");
    link.addDirectoryArg(stdlib_artifacts.library_dir);
    link.addFileArg(common);
    link.addFileArg(bytecomp);
    const main = engine.modules.get("driver/main") orelse return error.MissingCompilerMain;
    link.addFileArg(main.cmo orelse return error.MissingCompilerMain);

    for ([_][]const u8{ "config_boot", "config_main" }) |variant| {
        const source = try sources.resolve(b.fmt("utils/{s}.ml", .{variant}));
        const interface = ocaml.path("utils/config.mli");
        link.addFileInput(engine.variant(variant, interface, source));
    }

    return .{
        .executable = executable,
        .common_archive = common,
        .bytecomp_archive = bytecomp,
        .installed_interfaces = try installed.toOwnedSlice(b.allocator),
    };
}

fn stdlibSource(
    b: *Build,
    ocaml: *Build.Dependency,
    exe: *Compile,
    path: []const u8,
    aliases: bool,
) Build.LazyPath {
    const needs_sys = std.mem.eql(u8, path, "stdlib/sys.ml");
    if (!aliases and !needs_sys) return ocaml.path(path);

    const run = b.addRunArtifact(exe);
    run.addArg(if (aliases) "aliases" else "sys");
    run.addFileArg(ocaml.path(if (needs_sys) "stdlib/sys.ml.in" else path));
    if (needs_sys) run.addFileArg(ocaml.path("VERSION"));
    return run.addOutputFileArg(std.fs.path.basename(path));
}
