//! Running the freshly bootstrapped native compiler on the build machine.
const std = @import("std");
const Ocamlc = @import("ocamlc.zig");
const Manifest = @import("manifests/manifest.zig");
const LazyPath = std.Build.LazyPath;
const Ocamlopt = @This();

b: *std.Build,
ocamlrun: *std.Build.Step.Compile,
exe: LazyPath,
stdlib_dir: ?LazyPath,

pub const Options = struct {
    includes: []const LazyPath = &.{},
    flags: []const []const u8 = &.{},
    /// Skip `toplevel/` units when only building the compiler executables.
    skip_toplevel: bool = false,
};

pub fn cmd(self: Ocamlopt, opts: Options) *std.Build.Step.Run {
    const run = self.b.addRunArtifact(self.ocamlrun);
    // Build steps must find the Zig used by this build, even when it was invoked
    // by absolute path and is not otherwise on PATH.
    run.setEnvironmentVariable("PATH", self.b.fmt("{s}{s}{s}", .{
        std.fs.path.dirname(self.b.graph.zig_exe).?,
        if (self.b.graph.host.result.os.tag == .windows) ";" else ":",
        run.getEnvMap().get("PATH") orelse "",
    }));
    run.addFileArg(self.exe);
    run.addArg("-nostdlib");
    if (self.stdlib_dir) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
    for (opts.includes) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
    run.addArgs(opts.flags);
    return run;
}

pub const Impl = struct {
    cmx: LazyPath,
    obj: LazyPath,
};

/// Each compilation must see the `.cmx`s of its implementation dependencies.
pub fn impl(self: Ocamlopt, src: LazyPath, name: []const u8, cmi: LazyPath, opts: Options) Impl {
    const run = self.cmd(opts);
    run.addArg("-cmi-file");
    run.addFileArg(cmi);
    run.addArg("-o");
    const cmx = run.addOutputFileArg(self.b.fmt("{s}.cmx", .{name}));
    run.addArgs(&.{ "-c", "-impl" });
    run.addFileArg(src);
    return .{ .cmx = cmx, .obj = cmx.dirname().path(self.b, self.b.fmt("{s}.o", .{name})) };
}

pub const Archive = struct {
    cmxa: LazyPath,
    lib: LazyPath,
};

/// `ocamlopt -a` also archives the objects adjacent to the input `.cmx`s.
pub fn archive(self: Ocamlopt, name: []const u8, objs: []const LazyPath, opts: Options) Archive {
    const run = self.cmd(opts);
    run.addArgs(&.{ "-a", "-o" });
    const cmxa = run.addOutputFileArg(self.b.fmt("{s}.cmxa", .{name}));
    for (objs) |obj| run.addFileArg(obj);
    return .{ .cmxa = cmxa, .lib = cmxa.dirname().path(self.b, self.b.fmt("{s}.a", .{name})) };
}

pub fn shared(self: Ocamlopt, name: []const u8, archive_file: LazyPath, opts: Options) LazyPath {
    const run = self.cmd(opts);
    run.addArgs(&.{ "-shared", "-linkall", "-o" });
    const out = run.addOutputFileArg(self.b.fmt("{s}.cmxs", .{name}));
    run.addFileArg(archive_file);
    return out;
}

pub fn link(self: Ocamlopt, name: []const u8, objs: []const LazyPath, opts: Options) LazyPath {
    const run = self.cmd(opts);
    run.addArg("-o");
    const out = run.addOutputFileArg(name);
    for (objs) |obj| run.addFileArg(obj);
    return out;
}

pub const Compiled = struct {
    impls: std.StringArrayHashMapUnmanaged(struct { unit: Manifest.Unit, impl: Impl }) = .empty,
    skipped: std.StringHashMapUnmanaged(void) = .empty,
    dir: LazyPath,

    pub fn cmx(self: Compiled, key: []const u8) ?LazyPath {
        if (self.impls.get(key)) |u| return u.impl.cmx;
        if (self.skipped.contains(key)) return null;
        std.debug.panic("no native compilation unit '{s}' in plan", .{key});
    }

    pub fn cmxs(self: Compiled, b: *std.Build, keys: []const []const u8) []const LazyPath {
        var out: std.ArrayList(LazyPath) = .empty;
        for (keys) |key| if (self.cmx(key)) |path| {
            out.append(b.allocator, path) catch @panic("OOM");
        };
        return out.items;
    }
};

/// Native waves see the interfaces and implementations of every previous wave.
pub fn compilePlan(self: Ocamlopt, plan: Manifest.Plan, sources: @import("source.zig").Resolver, byte: Ocamlc.Compiled, opts: Options) Compiled {
    const b = self.b;
    var out: Compiled = .{ .dir = undefined };
    var includes: std.ArrayList(LazyPath) = .empty;
    includes.appendSlice(b.allocator, opts.includes) catch @panic("OOM");
    includes.append(b.allocator, byte.cmis_dir) catch @panic("OOM");
    const all = b.addWriteFiles();
    var cmis: std.StringHashMapUnmanaged(LazyPath) = .empty;
    for (byte.intfs.values()) |i| cmis.put(b.allocator, i.unit.name, i.cmi) catch @panic("OOM");
    for (plan.cmx_waves) |wave| {
        const stage = b.addWriteFiles();
        for (wave) |u| {
            if (!u.enabledFor(sources.arch) or (opts.skip_toplevel and std.mem.startsWith(u8, u.key, "toplevel/"))) {
                out.skipped.put(b.allocator, u.key, {}) catch @panic("OOM");
                continue;
            }
            const native = self.impl(sources.resolve(u.src), u.name, cmis.get(u.name).?, .{
                .includes = includes.items,
                .flags = Ocamlc.concat(b, Ocamlc.concat(b, opts.flags, u.flags), u.native_flags),
            });
            out.impls.put(b.allocator, u.key, .{ .unit = u, .impl = native }) catch @panic("OOM");
            _ = stage.addCopyFile(native.cmx, b.fmt("{s}.cmx", .{u.name}));
            _ = all.addCopyFile(native.cmx, b.fmt("{s}.cmx", .{u.name}));
        }
        includes.append(b.allocator, stage.getDirectory()) catch @panic("OOM");
    }
    out.dir = all.getDirectory();
    return out;
}
