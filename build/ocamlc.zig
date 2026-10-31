//! Running a bytecode `ocamlc` (the checked-in `boot/ocamlc` or a freshly built one)
//! under a build-machine `ocamlrun`.
const std = @import("std");
const Manifest = @import("manifests/manifest.zig");
const Resolver = @import("source.zig").Resolver;
const LazyPath = std.Build.LazyPath;

const Ocamlc = @This();

b: *std.Build,
ocamlrun: *std.Build.Step.Compile,
/// The `ocamlc` bytecode executable.
exe: LazyPath,
/// `-I <stdlib>`; `null` when compiling the stdlib itself.
stdlib_dir: ?LazyPath,
/// `-use-prims <file>`, needed for `boot/ocamlc`, which doesn't know the primitives
/// of the runtime it is targeting.
primitives: ?LazyPath,

pub const Options = struct {
    includes: []const LazyPath = &.{},
    flags: []const []const u8 = &.{},
};

/// `ocamlrun ocamlc -nostdlib [-I stdlib] [-use-prims p] -I includes... flags...`
pub fn cmd(self: Ocamlc, opts: Options) *std.Build.Step.Run {
    const run = self.b.addRunArtifact(self.ocamlrun);
    run.addFileArg(self.exe);
    run.addArg("-nostdlib");
    if (self.stdlib_dir) |d| {
        run.addArg("-I");
        run.addDirectoryArg(d);
    }
    if (self.primitives) |p| {
        run.addArg("-use-prims");
        run.addFileArg(p);
    }
    for (opts.includes) |d| {
        run.addArg("-I");
        run.addDirectoryArg(d);
    }
    run.addArgs(opts.flags);
    return run;
}

pub const Intf = struct {
    cmi: LazyPath,
    cmti: LazyPath,
};

/// Compile an interface to `<name>.cmi`.
pub fn intf(self: Ocamlc, src: LazyPath, name: []const u8, opts: Options) Intf {
    const run = self.cmd(opts);
    run.addArg("-o");
    const cmi = run.addOutputFileArg(self.b.fmt("{s}.cmi", .{name}));
    run.addArgs(&.{ "-c", "-intf" });
    run.addFileArg(src);
    return .{ .cmi = cmi, .cmti = cmi.dirname().path(self.b, self.b.fmt("{s}.cmti", .{name})) };
}

pub const Impl = struct {
    cmo: LazyPath,
    /// Only meaningful when compiled without `cmi_file`.
    cmi: LazyPath,
    cmt: LazyPath,
};

/// Compile an implementation to `<name>.cmo`. Without `cmi_file` this also emits
/// `<name>.cmi` (warning 70, "missing mli", is silenced).
pub fn impl(self: Ocamlc, src: LazyPath, name: []const u8, cmi_file: ?LazyPath, opts: Options) Impl {
    const run = self.cmd(opts);
    if (cmi_file) |cmi| {
        run.addArg("-cmi-file");
        run.addFileArg(cmi);
    } else {
        run.addArgs(&.{ "-w", "-70" });
    }
    run.addArg("-o");
    const cmo = run.addOutputFileArg(self.b.fmt("{s}.cmo", .{name}));
    run.addArgs(&.{ "-c", "-impl" });
    run.addFileArg(src);
    const dir = cmo.dirname();
    return .{
        .cmo = cmo,
        .cmi = dir.path(self.b, self.b.fmt("{s}.cmi", .{name})),
        .cmt = dir.path(self.b, self.b.fmt("{s}.cmt", .{name})),
    };
}

/// `ocamlc -a -o <out_name> objs...`
pub fn archive(self: Ocamlc, out_name: []const u8, objs: []const LazyPath, opts: Options) LazyPath {
    const run = self.cmd(opts);
    run.addArgs(&.{ "-a", "-o" });
    const out = run.addOutputFileArg(out_name);
    for (objs) |o| run.addFileArg(o);
    return out;
}

/// `ocamlc -o <out_name> objs...` (programs, `-pack`, ...)
pub fn link(self: Ocamlc, out_name: []const u8, objs: []const LazyPath, opts: Options) LazyPath {
    const run = self.cmd(opts);
    run.addArg("-o");
    const out = run.addOutputFileArg(out_name);
    for (objs) |o| run.addFileArg(o);
    return out;
}

/// The compiled form of a `Manifest.Plan`.
pub const Compiled = struct {
    /// Units that produced a `.cmi`, by key, in plan order.
    intfs: std.StringArrayHashMapUnmanaged(CompiledIntf) = .empty,
    /// Units that produced a `.cmo`, by key, in plan order.
    impls: std.StringArrayHashMapUnmanaged(CompiledImpl) = .empty,
    /// Keys skipped because they don't apply to the target architecture.
    skipped: std.StringHashMapUnmanaged(void) = .empty,
    /// Directory with every `.cmi` of the plan.
    cmis_dir: LazyPath,

    /// `null` if `key` was skipped for this architecture.
    pub fn cmo(self: Compiled, key: []const u8) ?LazyPath {
        if (self.impls.get(key)) |i| return i.impl.cmo;
        if (self.skipped.contains(key)) return null;
        std.debug.panic("no compilation unit '{s}' in plan", .{key});
    }

    /// The `.cmo`s of `keys`, in order, leaving out units skipped for this architecture.
    pub fn cmos(self: Compiled, b: *std.Build, keys: []const []const u8) []const LazyPath {
        var out: std.ArrayList(LazyPath) = .empty;
        for (keys) |k| {
            if (self.cmo(k)) |lp| out.append(b.allocator, lp) catch @panic("OOM");
        }
        return out.items;
    }
};

pub const CompiledIntf = struct {
    unit: Manifest.Unit,
    src: LazyPath,
    cmi: LazyPath,
    /// `.cmti` for `.mli`-compiled units, `null` for `.ml`-only units (see `impls`).
    cmti: ?LazyPath,
};

pub const CompiledImpl = struct {
    unit: Manifest.Unit,
    src: LazyPath,
    impl: Impl,
};

/// Compile every unit of `plan`: interfaces wave by wave (each wave sees all
/// earlier ones), then all implementations in parallel against the full set of `.cmi`s.
pub fn compilePlan(self: Ocamlc, plan: Manifest.Plan, sources: Resolver, opts: Options) Compiled {
    const b = self.b;
    const gpa = b.allocator;

    var out: Compiled = .{ .cmis_dir = undefined };
    var cmi_by_name: std.StringHashMapUnmanaged(LazyPath) = .empty;
    var includes: std.ArrayList(LazyPath) = .empty;
    includes.appendSlice(gpa, opts.includes) catch @panic("OOM");
    const all_cmis = b.addWriteFiles();

    for (plan.cmi_waves) |wave| {
        const wave_dir = b.addWriteFiles();
        for (wave) |wu| {
            const u = wu.unit;
            if (!u.enabledFor(sources.arch)) {
                out.skipped.put(gpa, u.key, {}) catch @panic("OOM");
                continue;
            }
            const src = sources.resolve(u.src);
            const unit_opts: Options = .{ .includes = includes.items, .flags = concat(b, opts.flags, u.flags) };
            const cmi_name = b.fmt("{s}.cmi", .{u.name});

            const cmi = switch (wu.kind) {
                .intf => blk: {
                    const r = self.intf(src, u.name, unit_opts);
                    out.intfs.put(gpa, u.key, .{ .unit = u, .src = src, .cmi = r.cmi, .cmti = r.cmti }) catch @panic("OOM");
                    break :blk r.cmi;
                },
                .impl => blk: {
                    const r = self.impl(src, u.name, null, unit_opts);
                    out.intfs.put(gpa, u.key, .{ .unit = u, .src = src, .cmi = r.cmi, .cmti = null }) catch @panic("OOM");
                    out.impls.put(gpa, u.key, .{ .unit = u, .src = src, .impl = r }) catch @panic("OOM");
                    break :blk r.cmi;
                },
            };
            _ = wave_dir.addCopyFile(cmi, cmi_name);
            _ = all_cmis.addCopyFile(cmi, cmi_name);
            cmi_by_name.put(gpa, u.name, cmi) catch @panic("OOM");
        }
        includes.append(gpa, wave_dir.getDirectory()) catch @panic("OOM");
    }

    out.cmis_dir = all_cmis.getDirectory();
    var impl_includes: std.ArrayList(LazyPath) = .empty;
    impl_includes.appendSlice(gpa, opts.includes) catch @panic("OOM");
    impl_includes.append(gpa, out.cmis_dir) catch @panic("OOM");

    for (plan.cmo_units) |u| {
        if (!u.enabledFor(sources.arch)) {
            out.skipped.put(gpa, u.key, {}) catch @panic("OOM");
            continue;
        }
        if (out.impls.contains(u.key)) continue;
        const src = sources.resolve(u.src);
        const cmi = cmi_by_name.get(u.name);
        const r = self.impl(src, u.name, cmi, .{
            .includes = impl_includes.items,
            .flags = concat(b, opts.flags, u.flags),
        });
        out.impls.put(gpa, u.key, .{ .unit = u, .src = src, .impl = r }) catch @panic("OOM");
        // no interface anywhere: this compilation produced the .cmi
        if (cmi == null) out.intfs.put(gpa, u.key, .{ .unit = u, .src = src, .cmi = r.cmi, .cmti = null }) catch @panic("OOM");
    }

    return out;
}

pub fn concat(b: *std.Build, a: []const []const u8, c: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ a, c }) catch @panic("OOM");
}

pub fn concatPaths(b: *std.Build, a: []const LazyPath, c: []const LazyPath) []const LazyPath {
    return std.mem.concat(b.allocator, LazyPath, &.{ a, c }) catch @panic("OOM");
}
