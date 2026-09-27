const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const Io = std.Io;

const Manifest = @import("tools/manifest.zig");

pub fn build(b: *Build) !void {
    const ocaml = b.dependency("ocaml", .{});
    addPrepareStep(b, ocaml);

    const ocaml_step = b.step("ocaml", "Bootstrap OCaml interpreter, standard library, and compiler");
    const build_machine = b.graph.host;
    if (build_machine.result.cpu.arch != .x86_64 or build_machine.result.os.tag != .linux) {
        ocaml_step.dependOn(&b.addFail("the OCaml runtime bootstrap requires an x86_64-linux build machine").step);
        return;
    }

    // Read at build-graph construction time, rather than importing a ZON file:
    // `zig build prepare` remains usable if the committed manifest is absent or stale.
    const text = Io.Dir.cwd().readFileAllocOptions(b.graph.io, "build/gen/manifest.zon", b.allocator, .unlimited, .of(u8), 0) catch {
        const failure = b.addFail("OCaml source manifest missing: run zig build prepare and review build/gen/manifest.zon");
        ocaml_step.dependOn(&failure.step);
        return;
    };

    const manifest = std.zon.parse.fromSliceAlloc(Manifest, b.allocator, text, null, .{}) catch {
        const failure = b.addFail("OCaml source manifest invalid: run zig build prepare and review build/gen/manifest.zon");
        ocaml_step.dependOn(&failure.step);
        return;
    };

    const hash = @import("build.zig.zon").dependencies.ocaml.hash;
    if (!std.mem.eql(u8, manifest.source_hash, hash)) {
        const failure = b.addFail("OCaml source changed: run zig build prepare and review build/gen/manifest.zon");
        ocaml_step.dependOn(&failure.step);
        return;
    }

    const version = std.SemanticVersion.parse(manifest.ocaml_version) catch {
        const failure = b.addFail("OCaml manifest has an invalid runtime version: run zig build prepare and review build/gen/manifest.zon");
        ocaml_step.dependOn(&failure.step);
        return;
    };

    const primitives = loadPrimitives(b, ocaml);
    const runtime = try addOcamlrun(b, ocaml, primitives.prims_c, manifest, version);

    ocaml_step.dependOn(&b.addInstallArtifact(runtime, .{}).step);
    ocaml_step.dependOn(&b.addInstallFile(primitives.names_file, "lib/ocaml/primitives").step);
    const stdlib = addStdlib(b, ocaml, runtime, ocaml.path("boot/ocamlc"), manifest, ocaml_step, true);
    if (stdlib) |built| {
        addCompiler(b, ocaml, runtime, primitives.names_file, manifest, built, ocaml_step);
    }
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

fn addOcamlrun(
    b: *Build,
    ocaml: *Build.Dependency,
    prims_c: Build.LazyPath,
    manifest: Manifest,
    version: std.SemanticVersion,
) !*Compile {
    const runtime = b.addExecutable(.{
        .name = "ocamlrun",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
        }),
    });

    runtime.root_module.addIncludePath(ocaml.path("runtime"));

    addRuntimeHeaders(b, ocaml, runtime, manifest, version);

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

    return runtime;
}

fn addRuntimeHeaders(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    manifest: Manifest,
    parsed_version: std.SemanticVersion,
) void {
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

    const version_number = parsed_version.major * 10000 + parsed_version.minor * 100 + parsed_version.patch;
    const version_header = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = ocaml.path("runtime/caml/version.h.in") },
        .include_path = "caml/version.h",
    }, .{
        .OCAML_VERSION_MAJOR = @as(i64, @intCast(parsed_version.major)),
        .OCAML_VERSION_MINOR = @as(i64, @intCast(parsed_version.minor)),
        .OCAML_VERSION_PATCHLEVEL = @as(i64, @intCast(parsed_version.patch)),
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
        .HOST = "x86_64-unknown-linux-gnu",
        .BYTECODE_RUNTIME_ID = "",
    });

    const headers = .{ machine_header, system_header, version_header, exec_header, build_header };
    inline for (&headers) |header| {
        runtime.root_module.addConfigHeader(header);

        // OCaml headers include generated headers by basename (e.g. "m.h").
        runtime.root_module.addIncludePath(header.getOutputDir().path(b, "caml"));
    }
}

fn addStdlib(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    compiler: Build.LazyPath,
    manifest: Manifest,
    step: *Build.Step,
    install: bool,
) ?Stdlib {
    const source_exe = b.addExecutable(.{
        .name = "stdlib-source",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/stdlib_source.zig"),
        }),
    });
    const compile_exe = b.addExecutable(.{
        .name = "stdlib-compile",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/stdlib_compile.zig"),
        }),
    });

    const n = manifest.stdlib_modules.len;
    const interface_dirs = b.allocator.alloc(Build.LazyPath, n) catch @panic("OOM");
    const implementation_dirs = b.allocator.alloc(Build.LazyPath, n) catch @panic("OOM");
    const cmo = b.allocator.alloc(Build.LazyPath, n) catch @panic("OOM");
    const interface_runs = b.allocator.alloc(*Build.Step.Run, n) catch @panic("OOM");
    const implementation_runs = b.allocator.alloc(*Build.Step.Run, n) catch @panic("OOM");
    var interface_by_path = std.StringHashMap(usize).init(b.allocator);

    for (manifest.stdlib_modules, 0..) |module, i| {
        const path = b.fmt("stdlib/{s}.cmi", .{module.output});
        const slot = interface_by_path.getOrPut(path) catch @panic("OOM");
        if (slot.found_existing) {
            const message = b.fmt("duplicate stdlib module in manifest: {s}", .{module.output});
            step.dependOn(&b.addFail(message).step);
            return null;
        }
        slot.value_ptr.* = i;

        const interface = stdlibSource(b, ocaml, source_exe, module.interface, module.expand_interface_aliases);
        const source = stdlibSource(b, ocaml, source_exe, module.source, module.expand_implementation_aliases);

        const Compilation = struct {
            mode: []const u8,
            run: **Build.Step.Run,
            dir: *Build.LazyPath,
        };
        for ([_]Compilation{
            .{ .mode = "interface", .run = &interface_runs[i], .dir = &interface_dirs[i] },
            .{ .mode = "implementation", .run = &implementation_runs[i], .dir = &implementation_dirs[i] },
        }) |entry| {
            const run = b.addRunArtifact(compile_exe);
            entry.run.* = run;
            run.addArtifactArg(runtime);
            run.addFileArg(compiler);
            run.addArg(module.output);
            run.addFileArg(interface);
            run.addFileArg(source);

            entry.dir.* = run.addOutputDirectoryArg(b.fmt("{s}-{s}", .{ module.output, entry.mode }));
            run.addArg(entry.mode);
            run.addArgs(module.interface_flags);
            run.addArg("--");
            run.addArgs(module.implementation_flags);
            run.addArg("--");
        }

        const cmi = interface_dirs[i].path(b, b.fmt("{s}.cmi", .{module.output}));
        implementation_runs[i].addFileArg(cmi);
        cmo[i] = implementation_dirs[i].path(b, b.fmt("{s}.cmo", .{module.output}));

        if (install) {
            step.dependOn(&b.addInstallFile(cmi, b.fmt("lib/ocaml/{s}.cmi", .{module.output})).step);
            step.dependOn(&b.addInstallFile(cmo[i], b.fmt("lib/ocaml/{s}.cmo", .{module.output})).step);
        }
    }

    for (manifest.stdlib_modules, 0..) |module, i| {
        const Output = struct {
            extension: []const u8,
            run: *Build.Step.Run,
        };
        for ([_]Output{
            .{ .extension = ".cmi", .run = interface_runs[i] },
            .{ .extension = ".cmo", .run = implementation_runs[i] },
        }) |entry| {
            const output = b.fmt("stdlib/{s}{s}", .{ module.output, entry.extension });
            var found = false;

            for (manifest.dependencies) |dependency| {
                if (!std.mem.eql(u8, dependency.output, output)) {
                    continue;
                }

                found = true;
                for (dependency.prerequisites) |prerequisite| {
                    if (std.mem.endsWith(u8, prerequisite, ".cmi")) {
                        const j = interface_by_path.get(prerequisite) orelse {
                            const message = b.fmt(
                                "stdlib dependency {s} requires missing interface {s}; review manifest and stdlib/.depend",
                                .{ output, prerequisite },
                            );
                            step.dependOn(&b.addFail(message).step);
                            return null;
                        };

                        if (j != i) {
                            entry.run.addDirectoryArg(interface_dirs[j]);

                            // The implementation step copies its interface and
                            // must see the interface's own prerequisites too.
                            if (std.mem.eql(u8, entry.extension, ".cmi")) {
                                implementation_runs[i].addDirectoryArg(interface_dirs[j]);
                            }
                        }
                    } else if (std.mem.endsWith(u8, prerequisite, ".cmo")) {
                        const cmi_path = b.fmt("{s}i", .{prerequisite[0 .. prerequisite.len - 1]});
                        const j = interface_by_path.get(cmi_path) orelse {
                            const message = b.fmt(
                                "stdlib dependency {s} requires missing bytecode module {s}; review manifest and stdlib/.depend",
                                .{ output, prerequisite },
                            );
                            step.dependOn(&b.addFail(message).step);
                            return null;
                        };

                        if (j != i) {
                            entry.run.addFileInput(cmo[j]);
                        }
                    } else if (!std.mem.endsWith(u8, prerequisite, ".ml") and
                        !std.mem.endsWith(u8, prerequisite, ".mli"))
                    {
                        const message = b.fmt(
                            "unsupported stdlib dependency {s} -> {s}; review manifest and stdlib/.depend",
                            .{ output, prerequisite },
                        );
                        step.dependOn(&b.addFail(message).step);
                        return null;
                    }
                }
            }

            if (!found) {
                const message = b.fmt(
                    "missing stdlib dependency rule for {s}; run zig build prepare and review stdlib/.depend",
                    .{output},
                );
                step.dependOn(&b.addFail(message).step);
                return null;
            }
        }
    }

    const archive = compilerRun(b, runtime, compiler);
    archive.addArg("-a");
    archive.addArg("-o");
    const cma = archive.addOutputFileArg("stdlib.cma");

    var archive_count: usize = 0;
    for (manifest.stdlib_modules, cmo) |module, item| {
        if (!module.archive_member) {
            continue;
        }

        archive.addFileArg(item);
        archive_count += 1;
    }
    if (archive_count == 0) {
        step.dependOn(&b.addFail("stdlib manifest has no archive members; run zig build prepare and review StdlibModules").step);
        return null;
    }

    if (install) step.dependOn(&b.addInstallFile(cma, "lib/ocaml/stdlib.cma").step);

    const interfaces = b.addWriteFiles();
    for (manifest.stdlib_modules, interface_dirs) |module, dir| {
        _ = interfaces.addCopyFile(dir.path(b, b.fmt("{s}.cmi", .{module.output})), b.fmt("{s}.cmi", .{module.output}));
    }
    _ = interfaces.addCopyFile(cmo[n - 1], "std_exit.cmo");
    _ = interfaces.addCopyFile(cma, "stdlib.cma");

    return .{ .interfaces = interfaces.getDirectory() };
}

const Stdlib = struct {
    interfaces: Build.LazyPath,
};

fn addCompiler(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    primitive_names: Build.LazyPath,
    manifest: Manifest,
    stdlib: Stdlib,
    step: *Build.Step,
) void {
    const generator = b.addExecutable(.{
        .name = "compiler-source",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/compiler_source.zig"),
        }),
    });
    const compile_exe = b.addExecutable(.{
        .name = "compiler-compile",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
            .root_source_file = b.path("tools/stdlib_compile.zig"),
        }),
    });

    var generated = std.StringHashMap(Build.LazyPath).init(b.allocator);
    addCompilerSources(b, ocaml, runtime, generator, primitive_names, manifest, &generated);

    const compiler = ocaml.path("boot/ocamlc");
    var modules = std.StringHashMap(CompilerModule).init(b.allocator);
    var archive_groups: [2]std.ArrayList(Build.LazyPath) = .{ .empty, .empty };

    // The common library's .cmx format interfaces name middle-end types.
    // Their interfaces are compiled on demand, without archiving native code.
    const groups = [_][]const u8{ "ocamlcommon", "ocamlbytecomp", "ocamlc", "ocamlmiddleend" };
    for (groups, 0..) |group_name, group_index| {
        const group = findGroup(manifest, group_name) orelse {
            step.dependOn(&b.addFail(b.fmt("missing compiler source group: {s}", .{group_name})).step);
            return;
        };

        for (group.files) |file| {
            const interface_only = std.mem.endsWith(u8, file, ".mli");
            if (interface_only and groupHasImplementation(group, file[0 .. file.len - 4])) continue;

            const path = if (interface_only or std.mem.endsWith(u8, file, ".mll"))
                b.fmt("{s}.ml", .{file[0 .. file.len - 4]})
            else if (std.mem.endsWith(u8, file, ".mly"))
                b.fmt("{s}.ml", .{file[0 .. file.len - 4]})
            else
                file;
            if (!std.mem.endsWith(u8, path, ".ml")) continue;

            const stem = path[0 .. path.len - 3];
            const module_name = std.fs.path.basename(stem);
            const mli_path = b.fmt("{s}.mli", .{stem});
            const has_interface = interface_only or groupHasSource(group, mli_path) or generated.contains(mli_path);
            const ml = if (interface_only) generated.get(mli_path) orelse ocaml.path(mli_path) else generated.get(path) orelse ocaml.path(path);
            const mli = if (has_interface) generated.get(mli_path) orelse ocaml.path(mli_path) else ml;

            const interface_run = if (has_interface) blk: {
                const run = compilerCompile(b, runtime, compiler, compile_exe, module_name, mli, ml, "interface", stdlib.interfaces);
                break :blk run;
            } else null;
            const implementation_run = if (interface_only) null else compilerCompile(
                b,
                runtime,
                compiler,
                compile_exe,
                module_name,
                mli,
                ml,
                if (has_interface) "implementation" else "standalone",
                stdlib.interfaces,
            );

            const interface_dir = if (interface_run) |run| run.output else implementation_run.?.output;
            const cmi = interface_dir.path(b, b.fmt("{s}.cmi", .{module_name}));
            if (has_interface and !interface_only) {
                implementation_run.?.run.addFileArg(cmi);
                implementation_run.?.run.addDirectoryArg(stdlib.interfaces);
            }

            const cmo = if (implementation_run) |run| run.output.path(b, b.fmt("{s}.cmo", .{module_name})) else null;
            if (modules.contains(stem)) {
                step.dependOn(&b.addFail(b.fmt("duplicate compiler module: {s}", .{stem})).step);
                return;
            }
            modules.put(stem, .{
                .interface_dir = interface_dir,
                .interface_run = if (interface_run) |run| run.run else null,
                .implementation_run = if (implementation_run) |run| run.run else null,
                .cmo = cmo,
            }) catch @panic("OOM");

            if (group_index < archive_groups.len and cmo != null) {
                archive_groups[group_index].append(b.allocator, cmo.?) catch @panic("OOM");
            }
            if (group_index < archive_groups.len) {
                step.dependOn(&b.addInstallFile(cmi, b.fmt("lib/ocaml/compiler-libs/{s}.cmi", .{module_name})).step);
            }
        }
    }

    for (groups) |group_name| {
        const group = findGroup(manifest, group_name).?;
        for (group.files) |file| {
            const interface_only = std.mem.endsWith(u8, file, ".mli");
            if (interface_only and groupHasImplementation(group, file[0 .. file.len - 4])) continue;
            const path = if (interface_only or std.mem.endsWith(u8, file, ".mll") or std.mem.endsWith(u8, file, ".mly"))
                b.fmt("{s}.ml", .{file[0 .. file.len - 4]})
            else
                file;
            if (!std.mem.endsWith(u8, path, ".ml")) continue;

            const stem = path[0 .. path.len - 3];
            const module = modules.get(stem).?;
            for ([_]struct { output: []const u8, run: ?*Build.Step.Run }{
                .{ .output = b.fmt("{s}.cmi", .{stem}), .run = module.interface_run },
                .{ .output = b.fmt("{s}.cmo", .{stem}), .run = module.implementation_run },
            }) |target| {
                const run = target.run orelse continue;
                var included = std.StringHashMap(void).init(b.allocator);
                var found = false;
                for (manifest.dependencies) |rule| {
                    if (!std.mem.eql(u8, rule.output, target.output) or rule.arch != null) continue;
                    found = true;
                    for (rule.prerequisites) |prerequisite| {
                        if (!std.mem.endsWith(u8, prerequisite, ".cmi") and
                            !std.mem.endsWith(u8, prerequisite, ".cmo")) continue;

                        const dependency = modules.get(prerequisite[0 .. prerequisite.len - 4]) orelse {
                            step.dependOn(&b.addFail(b.fmt("missing compiler dependency {s} -> {s}", .{ target.output, prerequisite })).step);
                            return;
                        };
                        if (std.mem.endsWith(u8, prerequisite, ".cmo")) {
                            if (std.mem.eql(u8, prerequisite[0 .. prerequisite.len - 4], stem)) continue;
                            run.addFileInput(dependency.cmo orelse {
                                step.dependOn(&b.addFail(b.fmt("implementation unavailable: {s}", .{prerequisite})).step);
                                return;
                            });
                        } else {
                            if (!std.mem.eql(u8, prerequisite[0 .. prerequisite.len - 4], stem)) {
                                includeCompilerInterface(b, run, prerequisite, &modules, manifest, &included);
                                if (module.interface_run != null and target.run == module.interface_run) {
                                    if (module.implementation_run) |implementation| {
                                        implementation.addDirectoryArg(dependency.interface_dir);
                                    }
                                }
                            }
                        }
                    }
                }
                if (!found) {
                    step.dependOn(&b.addFail(b.fmt("missing compiler dependency rule: {s}", .{target.output})).step);
                    return;
                }
                // A module's interface can expose aliases not spelled out in
                // the implementation's .depend rule (for example Types.Uid).
                if (module.interface_run != null and target.run == module.implementation_run) {
                    const own_cmi = b.fmt("{s}.cmi", .{stem});
                    includeCompilerPrerequisites(b, run, own_cmi, &modules, manifest, &included);
                }
            }
        }
    }

    const common = compilerArchive(b, runtime, compiler, "ocamlcommon.cma", archive_groups[0].items, true);
    const bytecomp = compilerArchive(b, runtime, compiler, "ocamlbytecomp.cma", archive_groups[1].items, false);
    step.dependOn(&b.addInstallFile(common, "lib/ocaml/compiler-libs/ocamlcommon.cma").step);
    step.dependOn(&b.addInstallFile(bytecomp, "lib/ocaml/compiler-libs/ocamlbytecomp.cma").step);

    const link = compilerRun(b, runtime, compiler);
    link.addArgs(&.{ "-compat-32", "-g", "-without-runtime", "-set-runtime-default" });
    link.addArg(b.fmt("standard_library_default={s}", .{b.getInstallPath(.lib, "ocaml")}));
    link.addArg("-o");
    const new_compiler = link.addOutputFileArg("ocamlc");
    link.addArg("-I");
    link.addDirectoryArg(stdlib.interfaces);
    link.addFileArg(common);
    link.addFileArg(bytecomp);
    link.addFileArg(modules.get("driver/main").?.cmo.?);
    for ([_][]const u8{ "config_boot", "config_main" }) |variant| {
        const source = generated.get(b.fmt("utils/{s}.ml", .{variant})).?;
        const interface = ocaml.path("utils/config.mli");
        const cmi_run = compilerCompile(b, runtime, compiler, compile_exe, variant, interface, source, "interface", stdlib.interfaces);
        const cmi = cmi_run.output.path(b, b.fmt("{s}.cmi", .{variant}));
        const cmo_run = compilerCompile(b, runtime, compiler, compile_exe, variant, interface, source, "implementation", stdlib.interfaces);
        cmo_run.run.addFileArg(cmi);
        cmo_run.run.addDirectoryArg(stdlib.interfaces);
        link.addFileInput(cmo_run.output.path(b, b.fmt("{s}.cmo", .{variant})));
    }
    step.dependOn(&b.addInstallFile(new_compiler, "bin/ocamlc").step);

    const validation = b.step("validate-ocaml", "Rebuild the standard library using source-built ocamlc and run a bytecode program");
    checkCompilerOutput(b, runtime, new_compiler, &.{"-version"}, b.fmt("{s}\n", .{manifest.ocaml_version}), validation);
    checkCompilerOutput(b, runtime, new_compiler, &.{ "-config-var", "native_compiler" }, "false", validation);
    checkCompilerOutput(b, runtime, new_compiler, &.{ "-config-var", "c_compiler" }, "zig cc", validation);
    checkCompilerOutput(
        b,
        runtime,
        new_compiler,
        &.{ "-config-var", "cmi_magic_number" },
        b.fmt("{s}I{s}", .{ manifest.magic_prefix, manifest.magic_version }),
        validation,
    );
    checkCompilerOutput(
        b,
        runtime,
        new_compiler,
        &.{"-where"},
        b.fmt("{s}\n", .{b.getInstallPath(.lib, "ocaml")}),
        validation,
    );
    const rebuilt = addStdlib(b, ocaml, runtime, new_compiler, manifest, validation, false) orelse return;

    const smoke_source = b.addWriteFiles();
    const smoke_ml = smoke_source.add("smoke.ml", "let numbers = List.map (fun n -> n * n) [1; 2; 3] in\n" ++
        "Printf.printf \"OCaml %s: %d\\n\" Sys.ocaml_version (List.fold_left ( + ) 0 numbers)\n");
    const smoke_link = Build.Step.Run.create(b, "link source-built OCaml smoke program");
    smoke_link.addArtifactArg(runtime);
    smoke_link.addFileArg(new_compiler);
    smoke_link.addArgs(&.{ "-nostdlib", "-without-runtime", "-I" });
    smoke_link.addDirectoryArg(rebuilt.interfaces);
    smoke_link.addArgs(&.{"-o"});
    const smoke_bytecode = smoke_link.addOutputFileArg("smoke.byte");
    smoke_link.addFileArg(smoke_ml);

    const execute = Build.Step.Run.create(b, "run source-built OCaml smoke program");
    execute.addArtifactArg(runtime);
    execute.addFileArg(smoke_bytecode);
    execute.expectStdOutEqual("OCaml 5.5.1: 14\n");
    validation.dependOn(&execute.step);
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

fn includeCompilerInterface(
    b: *Build,
    run: *Build.Step.Run,
    path: []const u8,
    modules: *const std.StringHashMap(CompilerModule),
    manifest: Manifest,
    included: *std.StringHashMap(void),
) void {
    if (included.contains(path)) return;
    included.put(path, {}) catch @panic("OOM");

    const module = modules.get(path[0 .. path.len - 4]) orelse {
        run.step.dependOn(&b.addFail(b.fmt("missing compiler interface dependency: {s}", .{path})).step);
        return;
    };
    run.addDirectoryArg(module.interface_dir);
    includeCompilerPrerequisites(b, run, path, modules, manifest, included);
}

fn includeCompilerPrerequisites(
    b: *Build,
    run: *Build.Step.Run,
    path: []const u8,
    modules: *const std.StringHashMap(CompilerModule),
    manifest: Manifest,
    included: *std.StringHashMap(void),
) void {
    const own_module = modules.get(path[0 .. path.len - 4]).?;
    for (manifest.dependencies) |rule| {
        const standalone_implementation = own_module.interface_run == null and
            std.mem.eql(u8, rule.output, b.fmt("{s}.cmo", .{path[0 .. path.len - 4]}));
        if ((!std.mem.eql(u8, rule.output, path) and !standalone_implementation) or rule.arch != null) continue;
        for (rule.prerequisites) |prerequisite| {
            if (std.mem.endsWith(u8, prerequisite, ".cmi") and
                !std.mem.eql(u8, prerequisite, path))
            {
                includeCompilerInterface(b, run, prerequisite, modules, manifest, included);
            }
        }
    }
}

const CompilerModule = struct {
    interface_dir: Build.LazyPath,
    interface_run: ?*Build.Step.Run,
    implementation_run: ?*Build.Step.Run,
    cmo: ?Build.LazyPath,
};

const CompilerRun = struct {
    run: *Build.Step.Run,
    output: Build.LazyPath,
};

fn compilerCompile(
    b: *Build,
    runtime: *Compile,
    compiler: Build.LazyPath,
    exe: *Compile,
    name: []const u8,
    interface: Build.LazyPath,
    implementation: Build.LazyPath,
    mode: []const u8,
    stdlib_dir: Build.LazyPath,
) CompilerRun {
    const run = b.addRunArtifact(exe);
    run.addArtifactArg(runtime);
    run.addFileArg(compiler);
    run.addArg(name);
    run.addFileArg(interface);
    run.addFileArg(implementation);
    const output = run.addOutputDirectoryArg(b.fmt("compiler-{s}-{s}", .{ name, mode }));
    run.addArg(mode);
    run.addArg("--");
    run.addArg("--");
    if (!std.mem.eql(u8, mode, "implementation")) run.addDirectoryArg(stdlib_dir);
    return .{ .run = run, .output = output };
}

fn compilerArchive(
    b: *Build,
    runtime: *Compile,
    compiler: Build.LazyPath,
    name: []const u8,
    files: []const Build.LazyPath,
    link_all: bool,
) Build.LazyPath {
    const run = compilerRun(b, runtime, compiler);
    if (link_all) run.addArg("-linkall");
    run.addArgs(&.{ "-a", "-o" });
    const archive = run.addOutputFileArg(name);
    for (files) |file| run.addFileArg(file);
    return archive;
}

fn findGroup(manifest: Manifest, name: []const u8) ?Manifest.SourceGroup {
    for (manifest.source_groups) |group| {
        if (std.mem.eql(u8, group.name, name)) return group;
    }
    return null;
}

fn groupHasSource(group: Manifest.SourceGroup, source: []const u8) bool {
    for (group.files) |file| {
        if (std.mem.eql(u8, file, source)) return true;
    }
    return false;
}

fn groupHasImplementation(group: Manifest.SourceGroup, stem: []const u8) bool {
    for (group.files) |file| {
        if (file.len < stem.len or !std.mem.startsWith(u8, file, stem)) continue;
        const suffix = file[stem.len..];
        if (std.mem.eql(u8, suffix, ".ml") or
            std.mem.eql(u8, suffix, ".mll") or
            std.mem.eql(u8, suffix, ".mly")) return true;
    }
    return false;
}

fn addCompilerSources(
    b: *Build,
    ocaml: *Build.Dependency,
    runtime: *Compile,
    generator: *Compile,
    primitives: Build.LazyPath,
    manifest: Manifest,
    generated: *std.StringHashMap(Build.LazyPath),
) void {
    const common_run = b.addRunArtifact(generator);
    common_run.addArg("config-common");
    common_run.addFileArg(ocaml.path("utils/config.common.ml.in"));
    common_run.addArg(manifest.magic_prefix);
    common_run.addArg(manifest.magic_version);
    const common = common_run.addOutputFileArg("config.common.ml");

    const configured_run = b.addRunArtifact(generator);
    configured_run.addArg("config-generated");
    configured_run.addFileArg(ocaml.path("utils/config.generated.ml.in"));
    configured_run.addArg(b.getInstallPath(.bin, ""));
    const configured = configured_run.addOutputFileArg("config.generated.ml");

    const main_run = b.addRunArtifact(generator);
    main_run.addArg("concat");
    main_run.addFileArg(configured);
    main_run.addFileArg(common);
    const main = main_run.addOutputFileArg("config.ml");
    generated.put("utils/config.ml", main) catch @panic("OOM");
    generated.put("utils/config_main.ml", main) catch @panic("OOM");

    const boot_run = b.addRunArtifact(generator);
    boot_run.addArg("concat");
    boot_run.addFileArg(ocaml.path("utils/config.fixed.ml"));
    boot_run.addFileArg(common);
    generated.put("utils/config_boot.ml", boot_run.addOutputFileArg("config_boot.ml")) catch @panic("OOM");

    const parser_files = [_]struct { output: []const u8, input: []const u8, mode: []const u8 }{
        .{ .output = "parsing/parser.ml", .input = "boot/menhir/parser.ml", .mode = "menhir" },
        .{ .output = "parsing/parser.mli", .input = "boot/menhir/parser.mli", .mode = "menhir" },
        .{ .output = "parsing/camlinternalMenhirLib.ml", .input = "boot/menhir/menhirLib.ml", .mode = "copy" },
        .{ .output = "parsing/camlinternalMenhirLib.mli", .input = "boot/menhir/menhirLib.mli", .mode = "menhir-interface" },
    };
    for (parser_files) |entry| {
        const run = b.addRunArtifact(generator);
        run.addArg(entry.mode);
        run.addFileArg(ocaml.path(entry.input));
        generated.put(entry.output, run.addOutputFileArg(std.fs.path.basename(entry.output))) catch @panic("OOM");
    }

    const runtime_def = b.addRunArtifact(generator);
    runtime_def.addArg("runtimedef");
    runtime_def.addFileArg(ocaml.path("runtime/caml/fail.h"));
    runtime_def.addFileArg(primitives);
    generated.put("lambda/runtimedef.ml", runtime_def.addOutputFileArg("runtimedef.ml")) catch @panic("OOM");

    for ([_][]const u8{ "opcodes", "opcodes-interface" }, 0..) |mode, i| {
        const run = b.addRunArtifact(generator);
        run.addArg(mode);
        run.addFileArg(ocaml.path("runtime/caml/instruct.h"));
        const output = if (i == 0) "bytecomp/opcodes.ml" else "bytecomp/opcodes.mli";
        generated.put(output, run.addOutputFileArg(std.fs.path.basename(output))) catch @panic("OOM");
    }

    // The .ml.c templates use OCaml syntax protected by C macros. Preprocess
    // with Zig's bundled C frontend; do not materialize anything in the source.
    const cpp_headers = b.addWriteFiles();
    _ = cpp_headers.add("m.h", "#define ARCH_SIXTYFOUR 1\n");
    _ = cpp_headers.add("s.h", "#define OCAML_OS_TYPE \"Unix\"\n");
    for ([_][]const u8{ "utils/domainstate.ml", "utils/domainstate.mli" }) |path| {
        const cpp = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-P", "-x", "c", "-I" });
        cpp.addDirectoryArg(cpp_headers.getDirectory());
        cpp.addArg("-I");
        cpp.addDirectoryArg(ocaml.path("runtime/caml"));
        cpp.addArg("-o");
        const output = cpp.addOutputFileArg(std.fs.path.basename(path));
        cpp.addFileArg(ocaml.path(b.fmt("{s}.c", .{path})));
        generated.put(path, output) catch @panic("OOM");
    }

    for ([_][]const u8{ "ocamlcommon", "ocamlbytecomp" }) |name| {
        const group = findGroup(manifest, name).?;
        for (group.files) |file| {
            if (!std.mem.endsWith(u8, file, ".mll")) continue;

            const run = Build.Step.Run.create(b, "run boot/ocamllex");
            run.addArtifactArg(runtime);
            run.addFileArg(ocaml.path("boot/ocamllex"));
            run.addArgs(&.{ "-q", "-o" });
            const output = b.fmt("{s}.ml", .{file[0 .. file.len - 4]});
            const ml = run.addOutputFileArg(std.fs.path.basename(output));
            run.addFileArg(ocaml.path(file));
            generated.put(output, ml) catch @panic("OOM");
        }
    }
}

fn compilerRun(b: *Build, runtime: *Compile, compiler: Build.LazyPath) *Build.Step.Run {
    const run = Build.Step.Run.create(b, "run boot/ocamlc");
    run.addArtifactArg(runtime);
    run.addFileArg(compiler);
    run.addArgs(&.{
        "-nostdlib",  "-strict-sequence",
        "-w",         "+a-4-9-41-42-44-45-48",
        "-principal",
    });

    return run;
}

fn stdlibSource(
    b: *Build,
    ocaml: *Build.Dependency,
    exe: *Compile,
    path: []const u8,
    aliases: bool,
) Build.LazyPath {
    const needs_sys = std.mem.eql(u8, path, "stdlib/sys.ml");
    if (!aliases and !needs_sys) {
        return ocaml.path(path);
    }

    const run = b.addRunArtifact(exe);
    run.addArg(if (aliases) "aliases" else if (needs_sys) "sys" else "copy");
    run.addFileArg(ocaml.path(if (needs_sys) "stdlib/sys.ml.in" else path));
    if (needs_sys) {
        run.addFileArg(ocaml.path("VERSION"));
    }

    return run.addOutputFileArg(std.fs.path.basename(path));
}
