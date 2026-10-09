//! The distribution compiler's coldstart stdlib, kept entirely in the cache.
//! See upstream stdlib/Makefile and stdlib/Compflags for the compilation rules.

const std = @import("std");
const LazyPath = std.Build.LazyPath;

const Runtime = @import("Runtime.zig");
const Gen = @import("Gen.zig");
const Sources = @import("Sources.zig");
const OCamlCompile = @import("OCamlCompile.zig");

const Bootstrap = @This();

compiler: OCamlCompile,

/// stdlib.cma, std_exit.cmo, interfaces, libcamlrun and runtime-launch-info.
boot_dir: LazyPath,

pub const Options = struct {
    src: LazyPath,
    gen: Gen,
    sources: *const Sources,
    runtime: *Runtime,
};

pub fn build(b: *std.Build, o: Options) !Bootstrap {
    if (o.sources.stdlib.modules.len != o.sources.stdlib.basenames.len) {
        return error.InvalidStdlibManifest;
    }

    const runtime = o.runtime;
    const compiler: OCamlCompile = .{
        .interpreter = runtime.ocamlrun(.normal),
        .compiler = o.src.path(b, "boot/ocamlc"),
    };

    const launcher = b.addExecutable(.{
        .name = "bootstrap-launcher",
        .root_module = b.createModule(.{
            .target = runtime.target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            .strip = true,
        }),
    });
    launcher.root_module.addIncludePath(runtime.generated.path(b, "runtime"));
    launcher.root_module.addCSourceFile(.{ .file = o.src.path(b, "stdlib/header.c") });

    const prepared = o.gen.bootstrapSources(b, .{
        .modules = o.sources.stdlib.basenames,
        .sys_ml = runtime.generated.path(b, "stdlib/sys.ml"),
        .launcher = launcher.getEmittedBin(),
    });

    var builder: Builder = .{
        .b = b,
        .compiler = compiler,
        .sources = o.sources,
        .prepared = prepared,
        .interfaces = try b.allocator.alloc(Interface, o.sources.stdlib.modules.len + 1),
    };
    @memset(builder.interfaces, .unseen);

    const stage = b.addWriteFiles();
    var objects: std.ArrayList(LazyPath) = .empty;

    for (o.sources.stdlib.modules, o.sources.stdlib.basenames) |module, basename| {
        const cmi = try builder.interface(module);
        _ = stage.addCopyFile(cmi, b.fmt("{s}.cmi", .{module}));

        const deps = try builder.interfaceInputs(b.fmt("{s}.cmo", .{module}), basename);
        const cmo = compiler.compile(b, .{
            .source = prepared.path(b, b.fmt("{s}.ml", .{basename})),
            .output_name = b.fmt("{s}.cmo", .{module}),
            .interfaces = deps,
            .interface_source = prepared.path(b, b.fmt("{s}.mli", .{basename})),
            .flags = try flags(b.allocator, basename, .implementation),
        });

        try objects.append(b.allocator, cmo);
    }

    const exit_cmi = try builder.interface("std_exit");
    const exit = compiler.compile(b, .{
        .source = prepared.path(b, "std_exit.ml"),
        .output_name = "std_exit.cmo",
        .interfaces = try builder.interfaceInputs("std_exit.cmo", "std_exit"),
        .interface_source = prepared.path(b, "std_exit.mli"),
        .flags = try flags(b.allocator, "std_exit", .implementation),
    });

    _ = stage.addCopyFile(exit, "std_exit.cmo");
    _ = stage.addCopyFile(exit_cmi, "std_exit.cmi");
    _ = stage.addCopyFile(compiler.archive(b, "stdlib.cma", objects.items), "stdlib.cma");
    _ = stage.addCopyFile(prepared.path(b, "runtime-launch-info"), "runtime-launch-info");
    _ = stage.addCopyFile(runtime.library(.{ .backend = .bytecode }).?.getEmittedBin(), "libcamlrun.a");

    return .{ .compiler = compiler, .boot_dir = stage.getDirectory() };
}

const Interface = union(enum) {
    unseen,
    visiting,
    done: LazyPath,
};

const Builder = struct {
    b: *std.Build,
    compiler: OCamlCompile,
    sources: *const Sources,
    prepared: LazyPath,
    interfaces: []Interface,

    fn interface(self: *Builder, module: []const u8) Error!LazyPath {
        const index = blk: {
            if (std.mem.eql(u8, module, "std_exit")) {
                break :blk self.sources.stdlib.modules.len;
            }

            for (self.sources.stdlib.modules, 0..) |name, i| {
                if (std.mem.eql(u8, name, module)) break :blk i;
            }

            std.log.err("unknown stdlib module '{s}'", .{module});
            return error.UnknownStdlibModule;
        };

        const item = &self.interfaces[index];
        switch (item.*) {
            .done => |output| return output,
            .visiting => {
                std.log.err("cyclic stdlib interface dependency at '{s}'", .{module});
                return error.CyclicStdlibDependency;
            },
            .unseen => {},
        }

        item.* = .visiting;
        errdefer item.* = .unseen;

        const basename = if (index == self.sources.stdlib.modules.len)
            "std_exit"
        else
            self.sources.stdlib.basenames[index];

        const output = self.compiler.compile(self.b, .{
            .source = self.prepared.path(self.b, self.b.fmt("{s}.mli", .{basename})),
            .output_name = self.b.fmt("{s}.cmi", .{module}),
            .interfaces = try self.interfaceInputs(self.b.fmt("{s}.cmi", .{module}), basename),
            .flags = try flags(self.b.allocator, basename, .interface),
        });

        item.* = .{ .done = output };
        return output;
    }

    fn interfaceInputs(self: *Builder, target: []const u8, basename: []const u8) ![]const LazyPath {
        var deps: std.StringArrayHashMapUnmanaged(LazyPath) = .empty;
        try self.collect(target, &deps);

        // Implicitly opened Stdlib is not represented by ocamldep's rules.
        if (!noPervasives(basename)) try self.collectInterface("stdlib.cmi", &deps);

        return deps.values();
    }

    fn collect(self: *Builder, target: []const u8, deps: *std.StringArrayHashMapUnmanaged(LazyPath)) Error!void {
        const rule = for (self.sources.depend.stdlib) |rule| {
            if (std.mem.eql(u8, rule.target, target)) break rule;
        } else {
            std.log.err("missing stdlib dependency rule for '{s}'", .{target});
            return error.MissingStdlibDependencyRule;
        };

        for (rule.deps) |dep| {
            if (std.mem.endsWith(u8, dep, ".cmi")) try self.collectInterface(dep, deps);
        }
    }

    fn collectInterface(self: *Builder, name: []const u8, deps: *std.StringArrayHashMapUnmanaged(LazyPath)) !void {
        if (deps.contains(name)) return;

        const output = try self.interface(name[0 .. name.len - ".cmi".len]);
        try deps.put(self.b.allocator, name, output);
        try self.collect(name, deps);
    }

    const Error = error{
        OutOfMemory,
        UnknownStdlibModule,
        CyclicStdlibDependency,
        MissingStdlibDependencyRule,
    };
};

fn noPervasives(basename: []const u8) bool {
    return std.mem.eql(u8, basename, "stdlib") or std.mem.startsWith(u8, basename, "camlinternalFormatBasics");
}

const Kind = enum { interface, implementation };
fn flags(gpa: std.mem.Allocator, basename: []const u8, kind: Kind) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(gpa);

    try result.appendSlice(gpa, &.{
        "-strict-sequence",
        "-absname",
        "-w",
        "+a-4-9-41-42-44-45-48",
        "-g",
        "-warn-error",
        "+A",
        "-bin-annot",
        "-principal",
    });

    if (noPervasives(basename)) {
        try result.append(gpa, "-nopervasives");
    }

    if (std.mem.eql(u8, basename, "stdlib")) {
        try result.appendSlice(gpa, &.{ "-no-alias-deps", "-w", "-49" });
    }

    if (std.mem.eql(u8, basename, "buffer")) {
        try result.appendSlice(gpa, &.{ "-w", "+A" });
    }

    for ([_][]const u8{ "camlinternalFormat", "printf", "format", "scanf" }) |name| {
        if (std.mem.eql(u8, basename, name)) {
            try result.appendSlice(gpa, &.{ "-w", "+A", "-w", "-fragile-match" });
        }
    }

    if (kind == .implementation and (std.mem.endsWith(u8, basename, "Labels") or std.mem.eql(u8, basename, "float"))) {
        try result.appendSlice(gpa, &.{ "-nolabels", "-no-alias-deps" });
    }

    if (kind == .interface and std.mem.eql(u8, basename, "oo")) {
        try result.append(gpa, "-no-principal");
    }

    return result.toOwnedSlice(gpa);
}
