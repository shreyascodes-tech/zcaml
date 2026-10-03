const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const Index = @import("manifest.zig").Index;

pub const Spec = struct {
    stem: []const u8,
    name: []const u8,
    interface: ?Build.LazyPath,
    implementation: ?Build.LazyPath,
    interface_flags: []const []const u8 = &.{},
    implementation_flags: []const []const u8 = &.{},
};

pub const Module = struct {
    cmi: Build.LazyPath,
    cmo: ?Build.LazyPath,
    interface_dir: Build.LazyPath,
    interface_run: ?*Build.Step.Run,
    implementation_run: ?*Build.Step.Run,
};

pub const Engine = struct {
    b: *Build,
    runtime: *Compile,
    compiler: Build.LazyPath,
    helper: *Compile,
    index: *const Index,
    modules: std.StringHashMap(Module),
    base_interfaces: ?Build.LazyPath,

    pub fn init(
        b: *Build,
        runtime: *Compile,
        compiler: Build.LazyPath,
        index: *const Index,
        base_interfaces: ?Build.LazyPath,
    ) Engine {
        const helper = b.addExecutable(.{
            .name = "ocaml-module-compile",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .optimize = .Debug,
                .root_source_file = b.path("tools/ocaml_compile.zig"),
            }),
        });
        return .{
            .b = b,
            .runtime = runtime,
            .compiler = compiler,
            .helper = helper,
            .index = index,
            .modules = std.StringHashMap(Module).init(b.allocator),
            .base_interfaces = base_interfaces,
        };
    }

    pub fn add(self: *Engine, spec: Spec) !void {
        if (self.modules.contains(spec.stem)) {
            return self.problem("duplicate module", spec.stem, spec.stem);
        }
        if (spec.interface == null and spec.implementation == null) {
            return self.problem("module has no sources", spec.stem, spec.stem);
        }

        const interface_source = spec.interface orelse spec.implementation.?;
        const implementation_source = spec.implementation orelse interface_source;
        const interface_run = if (spec.interface != null)
            self.compile(spec, interface_source, implementation_source, "interface")
        else
            null;
        const implementation_run = if (spec.implementation != null)
            self.compile(
                spec,
                interface_source,
                implementation_source,
                if (spec.interface != null) "implementation" else "standalone",
            )
        else
            null;

        const interface_dir = if (interface_run) |run| run.dir else implementation_run.?.dir;
        const cmi = interface_dir.path(self.b, self.b.fmt("{s}.cmi", .{spec.name}));
        if (interface_run != null and implementation_run != null) {
            // The helper's own interface has a dedicated argument, before the
            // two flag lists and the dependency include directories.
            implementation_run.?.run.addFileArg(cmi);
        } else if (implementation_run) |run| {
            run.run.addArg("-");
        }
        if (interface_run) |run| run.run.addArg("-");

        const cmo = if (implementation_run) |run|
            run.dir.path(self.b, self.b.fmt("{s}.cmo", .{spec.name}))
        else
            null;

        try self.modules.put(spec.stem, .{
            .cmi = cmi,
            .cmo = cmo,
            .interface_dir = interface_dir,
            .interface_run = if (interface_run) |run| run.run else null,
            .implementation_run = if (implementation_run) |run| run.run else null,
        });
    }

    const Run = struct {
        run: *Build.Step.Run,
        dir: Build.LazyPath,
    };

    fn compile(
        self: *Engine,
        spec: Spec,
        interface: Build.LazyPath,
        implementation: Build.LazyPath,
        mode: []const u8,
    ) Run {
        const run = self.b.addRunArtifact(self.helper);
        run.addArtifactArg(self.runtime);
        run.addFileArg(self.compiler);
        run.addArg(spec.name);
        run.addFileArg(interface);
        run.addFileArg(implementation);
        const dir = run.addOutputDirectoryArg(self.b.fmt("{s}-{s}", .{ spec.name, mode }));
        run.addArg(mode);
        // add() supplies the dedicated own-interface argument; wire() adds
        // both flag lists before appending any dependency directories.
        return .{ .run = run, .dir = dir };
    }

    pub fn wire(self: *Engine, specs: []const Spec) !void {
        // A prerequisite can add include directories to another module's
        // implementation command. Complete every command's flag protocol
        // before wiring any of those cross-module dependencies.
        for (specs) |spec| {
            const module = self.modules.get(spec.stem).?;
            if (module.interface_run) |run| {
                addFlags(run, spec.interface_flags, spec.implementation_flags);
            }
            if (module.implementation_run) |run| {
                addFlags(run, spec.interface_flags, spec.implementation_flags);
            }
        }

        for (specs) |spec| {
            const module = self.modules.get(spec.stem).?;
            if (module.interface_run) |run| {
                try self.dependencies(spec.stem, module, run, true);
            }
            if (module.implementation_run) |run| {
                try self.dependencies(spec.stem, module, run, false);
            }
        }
    }

    fn addFlags(
        run: *Build.Step.Run,
        interface: []const []const u8,
        implementation: []const []const u8,
    ) void {
        run.addArgs(interface);
        run.addArg("--");
        run.addArgs(implementation);
        run.addArg("--");
    }

    fn dependencies(
        self: *Engine,
        stem: []const u8,
        module: Module,
        run: *Build.Step.Run,
        interface: bool,
    ) !void {
        const output = self.b.fmt("{s}.{s}", .{ stem, if (interface) @as([]const u8, "cmi") else "cmo" });
        const prerequisites = self.index.rules.get(output) orelse {
            return self.problem("missing dependency rule", output, output);
        };
        var included = std.StringHashMap(void).init(self.b.allocator);

        if (self.base_interfaces) |base| run.addDirectoryArg(base);
        for (prerequisites.items) |prerequisite| {
            if (std.mem.endsWith(u8, prerequisite, ".cmi")) {
                const dependency_stem = prerequisite[0 .. prerequisite.len - 4];
                if (std.mem.eql(u8, dependency_stem, stem)) continue;

                try self.include(run, output, prerequisite, &included);
                if (interface) {
                    if (module.implementation_run) |implementation| {
                        const dependency = self.modules.get(dependency_stem) orelse {
                            return self.problem("missing interface dependency", output, prerequisite);
                        };
                        implementation.addDirectoryArg(dependency.interface_dir);
                    }
                }
            } else if (std.mem.endsWith(u8, prerequisite, ".cmo")) {
                const dependency_stem = prerequisite[0 .. prerequisite.len - 4];
                if (std.mem.eql(u8, stem, dependency_stem)) continue;
                const dependency = self.modules.get(dependency_stem) orelse {
                    return self.problem("missing bytecode dependency", output, prerequisite);
                };
                const cmo = dependency.cmo orelse {
                    return self.problem("dependency has no implementation", output, prerequisite);
                };
                run.addFileInput(cmo);
            } else if (!std.mem.endsWith(u8, prerequisite, ".ml") and
                !std.mem.endsWith(u8, prerequisite, ".mli"))
            {
                return self.problem("unsupported dependency", output, prerequisite);
            }
        }

        // An implementation can use types exported by its own interface even
        // when its .cmo rule does not mention their defining interfaces.
        if (!interface and module.interface_run != null) {
            const own_cmi = self.b.fmt("{s}.cmi", .{stem});
            try self.includePrerequisites(run, output, own_cmi, &included);
        }
    }

    fn include(
        self: *Engine,
        run: *Build.Step.Run,
        owner: []const u8,
        path: []const u8,
        included: *std.StringHashMap(void),
    ) anyerror!void {
        if (included.contains(path)) return;
        try included.put(path, {});

        const dependency = self.modules.get(path[0 .. path.len - 4]) orelse {
            return self.problem("missing interface dependency", owner, path);
        };
        run.addDirectoryArg(dependency.interface_dir);
        try self.includePrerequisites(run, owner, path, included);
    }

    fn includePrerequisites(
        self: *Engine,
        run: *Build.Step.Run,
        owner: []const u8,
        path: []const u8,
        included: *std.StringHashMap(void),
    ) anyerror!void {
        const stem = path[0 .. path.len - 4];
        const module = self.modules.get(stem) orelse {
            return self.problem("missing interface dependency", owner, path);
        };
        const rule_path = if (module.interface_run == null)
            self.b.fmt("{s}.cmo", .{stem})
        else
            path;
        const prerequisites = self.index.rules.get(rule_path) orelse {
            return self.problem("missing dependency rule for interface", owner, rule_path);
        };
        for (prerequisites.items) |prerequisite| {
            if (std.mem.endsWith(u8, prerequisite, ".cmi") and
                !std.mem.eql(u8, prerequisite, path))
            {
                try self.include(run, owner, prerequisite, included);
            }
        }
    }

    pub fn archive(self: *Engine, name: []const u8) !Build.LazyPath {
        const definition = try self.index.archive(name);
        const run = compilerRun(self.b, self.runtime, self.compiler);
        if (definition.link_all) run.addArg("-linkall");
        run.addArgs(&.{ "-a", "-o" });
        const archive_name = self.b.fmt("{s}.cma", .{name});
        const output = run.addOutputFileArg(archive_name);
        for (definition.members) |stem| {
            const module = self.modules.get(stem) orelse {
                return self.problem("missing archive member", archive_name, stem);
            };
            const cmo = module.cmo orelse {
                return self.problem("archive member has no implementation", archive_name, stem);
            };
            run.addFileArg(cmo);
        }
        return output;
    }

    fn problem(
        self: *Engine,
        cause: []const u8,
        owner: []const u8,
        path: []const u8,
    ) error{InvalidOcamlGraph} {
        _ = self;
        std.log.err("OCaml graph {s}: {s} -> {s}", .{ cause, owner, path });
        return error.InvalidOcamlGraph;
    }

    /// Compile a second configuration variant outside the manifest module
    /// inventory, with the same isolated-output helper protocol.
    pub fn variant(
        self: *Engine,
        name: []const u8,
        interface: Build.LazyPath,
        source: Build.LazyPath,
    ) Build.LazyPath {
        const spec: Spec = .{
            .stem = name,
            .name = name,
            .interface = interface,
            .implementation = source,
        };
        const interface_run = self.compile(spec, interface, source, "interface");
        interface_run.run.addArgs(&.{ "-", "--", "--" });
        if (self.base_interfaces) |base| interface_run.run.addDirectoryArg(base);

        const own_cmi = interface_run.dir.path(self.b, self.b.fmt("{s}.cmi", .{name}));
        const implementation_run = self.compile(spec, interface, source, "implementation");
        implementation_run.run.addFileArg(own_cmi);
        implementation_run.run.addArgs(&.{ "--", "--" });
        if (self.base_interfaces) |base| implementation_run.run.addDirectoryArg(base);

        return implementation_run.dir.path(self.b, self.b.fmt("{s}.cmo", .{name}));
    }
};

pub fn compilerRun(
    b: *Build,
    runtime: *Compile,
    compiler: Build.LazyPath,
) *Build.Step.Run {
    const run = Build.Step.Run.create(b, "run OCaml bytecode compiler");
    run.addArtifactArg(runtime);
    run.addFileArg(compiler);
    run.addArgs(&.{ "-nostdlib", "-strict-sequence", "-w", "+a-4-9-41-42-44-45-48", "-principal" });
    return run;
}
