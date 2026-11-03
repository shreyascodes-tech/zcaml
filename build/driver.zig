//! Build drivers for bytecode (`ocamlc`) and native (`ocamlopt`) compilation.
const std = @import("std");
const Manifest = @import("manifests/manifest.zig");
const Resolver = @import("source.zig").Resolver;
const LazyPath = std.Build.LazyPath;
const SMap = std.StringHashMapUnmanaged;
const SArrayMap = std.StringArrayHashMapUnmanaged;

pub const Ocamlc = struct {
    b: *std.Build,
    ocamlrun: *std.Build.Step.Compile,
    /// The `ocamlc` bytecode executable.
    exe: LazyPath,
    /// `-I <stdlib>`; `null` when compiling the stdlib itself.
    stdlib_dir: ?LazyPath,
    /// `-use-prims <file>`, needed for `boot/ocamlc`, which doesn't know the primitives
    /// of the runtime it is targeting.
    primitives: ?LazyPath,
    prefix_map: ?[]const u8 = null,
    /// Working directory for compiling in-tree sources by relative path.
    cwd: ?LazyPath = null,
    strip_dir: ?[]const u8 = null,

    pub const Options = struct {
        includes: []const LazyPath = &.{},
        flags: []const []const u8 = &.{},
        rel_src: ?[]const u8 = null,
        /// Reuse already-compiled arch-independent units from an earlier `compilePlan`.
        reuse_frontend: ?Compiled = null,
        /// Only compile frontend (arch-independent) units; skip arch-dependent units.
        only_frontend: bool = false,
    };

    /// `ocamlrun ocamlc -nostdlib [-I stdlib] [-use-prims p] -I includes... flags...`
    pub fn cmd(self: Ocamlc, opts: Options) *std.Build.Step.Run {
        const run = self.b.addRunArtifact(self.ocamlrun);
        if (self.prefix_map) |pm| run.setEnvironmentVariable("BUILD_PATH_PREFIX_MAP", pm);
        if (opts.rel_src != null) if (self.cwd) |cwd| run.setCwd(cwd);
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
        addSourceArg(run, src, opts.rel_src);
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
        addSourceArg(run, src, opts.rel_src);
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
        intfs: SArrayMap(CompiledIntf) = .empty,
        /// Units that produced a `.cmo`, by key, in plan order.
        impls: SArrayMap(CompiledImpl) = .empty,
        /// Keys skipped because they don't apply to the target architecture.
        skipped: SMap(void) = .empty,
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
        var cmi_by_name: SMap(LazyPath) = .empty;
        var includes: std.ArrayList(LazyPath) = .empty;
        includes.appendSlice(gpa, opts.includes) catch @panic("OOM");
        if (opts.reuse_frontend) |fe| {
            includes.append(gpa, fe.cmis_dir) catch @panic("OOM");
        }
        const all_cmis = b.addWriteFiles();

        for (plan.cmi_waves) |wave| {
            var wave_dir: ?*std.Build.Step.WriteFile = null;
            for (wave) |wu| {
                const u = wu.unit;
                if (opts.only_frontend and isArchDependent(u.key)) {
                    out.skipped.put(gpa, u.key, {}) catch @panic("OOM");
                    continue;
                }
                if (!u.enabledFor(sources.arch) or !sources.has(u.src)) {
                    out.skipped.put(gpa, u.key, {}) catch @panic("OOM");
                    continue;
                }
                const cmi_name = b.fmt("{s}.cmi", .{u.name});
                if (opts.reuse_frontend) |fe| {
                    if (!isArchDependent(u.key)) {
                        const prev = fe.intfs.get(u.key).?;
                        out.intfs.put(gpa, u.key, prev) catch @panic("OOM");
                        if (wu.kind == .impl) out.impls.put(gpa, u.key, fe.impls.get(u.key).?) catch @panic("OOM");
                        _ = all_cmis.addCopyFile(prev.cmi, cmi_name);
                        cmi_by_name.put(gpa, u.name, prev.cmi) catch @panic("OOM");
                        continue;
                    }
                }
                const src = sources.resolve(u.src);
                const base_flags = concat(b, opts.flags, u.flags);
                const unit_opts: Options = .{
                    .includes = includes.items,
                    .flags = if (std.mem.eql(u8, u.key, "utils/config")) concat(b, base_flags, &.{"-opaque"}) else base_flags,
                    .rel_src = if (self.cwd != null) sources.relPath(u.src, self.strip_dir) else null,
                };

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
                const wd = wave_dir orelse blk: {
                    const wf = b.addWriteFiles();
                    wave_dir = wf;
                    break :blk wf;
                };
                _ = wd.addCopyFile(cmi, cmi_name);
                _ = all_cmis.addCopyFile(cmi, cmi_name);
                cmi_by_name.put(gpa, u.name, cmi) catch @panic("OOM");
            }
            if (wave_dir) |wd| {
                includes.append(gpa, wd.getDirectory()) catch @panic("OOM");
            }
        }

        out.cmis_dir = all_cmis.getDirectory();
        var impl_includes: std.ArrayList(LazyPath) = .empty;
        impl_includes.appendSlice(gpa, opts.includes) catch @panic("OOM");
        impl_includes.append(gpa, out.cmis_dir) catch @panic("OOM");

        for (plan.cmo_units) |u| {
            if (opts.only_frontend and isArchDependent(u.key)) {
                out.skipped.put(gpa, u.key, {}) catch @panic("OOM");
                continue;
            }
            if (!u.enabledFor(sources.arch) or !sources.has(u.src)) {
                out.skipped.put(gpa, u.key, {}) catch @panic("OOM");
                continue;
            }
            if (out.impls.contains(u.key)) continue;
            if (opts.reuse_frontend) |fe| {
                if (!isArchDependent(u.key)) {
                    const prev = fe.impls.get(u.key).?;
                    out.impls.put(gpa, u.key, prev) catch @panic("OOM");
                    if (cmi_by_name.get(u.name) == null) out.intfs.put(gpa, u.key, fe.intfs.get(u.key).?) catch @panic("OOM");
                    continue;
                }
            }
            const src = sources.resolve(u.src);
            const cmi = cmi_by_name.get(u.name);
            const r = self.impl(src, u.name, cmi, .{
                .includes = impl_includes.items,
                .flags = concat(b, opts.flags, u.flags),
                .rel_src = if (self.cwd != null) sources.relPath(u.src, self.strip_dir) else null,
            });
            out.impls.put(gpa, u.key, .{ .unit = u, .src = src, .impl = r }) catch @panic("OOM");
            // no interface anywhere: this compilation produced the .cmi
            if (cmi == null) out.intfs.put(gpa, u.key, .{ .unit = u, .src = src, .cmi = r.cmi, .cmti = null }) catch @panic("OOM");
        }

        return out;
    }
};

/// Links Windows executables and DLLs at build time.
pub const Flexlink = struct {
    exe: LazyPath,
    support_dir: LazyPath,
    flags: []const []const u8,

    pub fn run(self: Flexlink, b: *std.Build) *std.Build.Step.Run {
        const run_step = std.Build.Step.Run.create(b, "run flexlink");
        run_step.addFileArg(self.exe);
        addZigToPath(b, run_step);
        run_step.addArgs(self.flags);
        run_step.addArg("-I");
        run_step.addDirectoryArg(self.support_dir);
        return run_step;
    }

    /// `-cc` replaces `Config.mkexe`/`mkdll`.
    fn addOcamloptArgs(self: Flexlink, b: *std.Build, run_step: *std.Build.Step.Run, mode: enum { exe, dll }, strip: bool) void {
        run_step.addArg("-cc");
        run_step.addFileArg(self.exe);
        var opts: std.ArrayList(u8) = .empty;
        if (mode == .exe) opts.appendSlice(b.allocator, "-exe ") catch @panic("OOM");
        for (self.flags) |f| opts.print(b.allocator, "{s} ", .{f}) catch @panic("OOM");
        if (mode == .exe) opts.appendSlice(b.allocator, "-link -municode ") catch @panic("OOM");
        if (strip) opts.appendSlice(b.allocator, "-link -s ") catch @panic("OOM");
        run_step.addArgs(&.{ "-ccopt", std.mem.trimEnd(u8, opts.items, " ") });
        run_step.addArg("-I");
        run_step.addDirectoryArg(self.support_dir);
    }
};

/// Build steps must find the Zig used by this build, even when it was invoked
/// by absolute path and is not otherwise on PATH.
pub fn addZigToPath(b: *std.Build, run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("PATH", b.fmt("{s}{s}{s}", .{
        std.fs.path.dirname(b.graph.zig_exe).?,
        if (b.graph.host.result.os.tag == .windows) ";" else ":",
        run.getEnvMap().get("PATH") orelse "",
    }));
}

pub const Ocamlopt = struct {
    b: *std.Build,
    ocamlrun: ?*std.Build.Step.Compile = null,
    exe: LazyPath,
    stdlib_dir: ?LazyPath,
    flexlink: ?Flexlink = null,
    prefix_map: ?[]const u8 = null,
    cwd: ?LazyPath = null,
    strip_dir: ?[]const u8 = null,

    pub const Options = struct {
        includes: []const LazyPath = &.{},
        flags: []const []const u8 = &.{},
        /// Skip `toplevel/` units when only building the compiler executables.
        skip_toplevel: bool = false,
        rel_src: ?[]const u8 = null,
        /// Remove linker-supplied CRT/compiler-rt DWARF from installed executables.
        strip_debug: bool = false,
        /// Reuse already-compiled arch-independent units from an earlier `compilePlan`.
        reuse_frontend: ?Compiled = null,
    };

    pub fn cmd(self: Ocamlopt, opts: Options) *std.Build.Step.Run {
        const run = if (self.ocamlrun) |orun| self.b.addRunArtifact(orun) else std.Build.Step.Run.create(self.b, "run ocamlopt");
        run.addFileArg(self.exe);
        if (self.prefix_map) |pm| run.setEnvironmentVariable("BUILD_PATH_PREFIX_MAP", pm);
        if (opts.rel_src != null) if (self.cwd) |cwd| run.setCwd(cwd);
        addZigToPath(self.b, run);
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
        addSourceArg(run, src, opts.rel_src);
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
        if (self.flexlink) |fl| {
            fl.addOcamloptArgs(self.b, run, .dll, opts.strip_debug);
        } else if (opts.strip_debug) run.addArgs(&.{ "-ccopt", "-Wl,-S" });
        run.addArgs(&.{ "-shared", "-linkall", "-o" });
        const out = run.addOutputFileArg(self.b.fmt("{s}.cmxs", .{name}));
        run.addFileArg(archive_file);
        return out;
    }

    pub fn link(self: Ocamlopt, name: []const u8, objs: []const LazyPath, opts: Options) LazyPath {
        const run = self.cmd(opts);
        if (self.flexlink) |fl| {
            fl.addOcamloptArgs(self.b, run, .exe, opts.strip_debug);
        } else if (opts.strip_debug) run.addArgs(&.{ "-ccopt", "-Wl,-S" });
        run.addArg("-o");
        const out = run.addOutputFileArg(name);
        for (objs) |obj| run.addFileArg(obj);
        return out;
    }

    pub const Compiled = struct {
        impls: SArrayMap(struct { unit: Manifest.Unit, impl: Impl }) = .empty,
        skipped: SMap(void) = .empty,
        dir: LazyPath,
        frontend_dir: ?LazyPath = null,

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
    pub fn compilePlan(self: Ocamlopt, plan: Manifest.Plan, sources: Resolver, byte: Ocamlc.Compiled, opts: Options) Compiled {
        const b = self.b;
        var out: Compiled = .{ .dir = undefined };
        var includes: std.ArrayList(LazyPath) = .empty;
        includes.appendSlice(b.allocator, opts.includes) catch @panic("OOM");
        includes.append(b.allocator, byte.cmis_dir) catch @panic("OOM");
        if (opts.reuse_frontend) |fe| {
            includes.append(b.allocator, fe.frontend_dir.?) catch @panic("OOM");
        }
        const all = b.addWriteFiles();
        const fe_wf: ?*std.Build.Step.WriteFile = if (opts.reuse_frontend == null) b.addWriteFiles() else null;
        var cmis: SMap(LazyPath) = .empty;
        for (byte.intfs.values()) |i| cmis.put(b.allocator, i.unit.name, i.cmi) catch @panic("OOM");
        for (plan.cmx_waves) |wave| {
            var stage: ?*std.Build.Step.WriteFile = null;
            for (wave) |u| {
                if (!u.enabledFor(sources.arch) or !sources.has(u.src) or (opts.skip_toplevel and std.mem.startsWith(u8, u.key, "toplevel/"))) {
                    out.skipped.put(b.allocator, u.key, {}) catch @panic("OOM");
                    continue;
                }
                const reused: ?Impl = if (opts.reuse_frontend) |fe|
                    if (!isArchDependent(u.key)) if (fe.impls.get(u.key)) |prev| prev.impl else null else null
                else
                    null;
                const native = reused orelse self.impl(sources.resolve(u.src), u.name, cmis.get(u.name).?, .{
                    .includes = includes.items,
                    .flags = concat(b, concat(b, opts.flags, u.flags), u.native_flags),
                    .rel_src = if (self.cwd != null) sources.relPath(u.src, self.strip_dir) else null,
                });
                out.impls.put(b.allocator, u.key, .{ .unit = u, .impl = native }) catch @panic("OOM");
                const cmx_name = b.fmt("{s}.cmx", .{u.name});
                if (reused == null and !std.mem.eql(u8, u.key, "utils/config")) {
                    const st = stage orelse blk: {
                        const wf = b.addWriteFiles();
                        stage = wf;
                        break :blk wf;
                    };
                    _ = st.addCopyFile(native.cmx, cmx_name);
                }
                if (!std.mem.eql(u8, u.key, "utils/config")) {
                    _ = all.addCopyFile(native.cmx, cmx_name);
                    if (fe_wf) |fwf| {
                        if (!isArchDependent(u.key)) {
                            _ = fwf.addCopyFile(native.cmx, cmx_name);
                        }
                    }
                }
            }
            if (stage) |st| {
                includes.append(b.allocator, st.getDirectory()) catch @panic("OOM");
            }
        }
        out.dir = all.getDirectory();
        out.frontend_dir = if (fe_wf) |fwf| fwf.getDirectory() else null;
        return out;
    }
};

fn addSourceArg(run: *std.Build.Step.Run, src: LazyPath, rel_src: ?[]const u8) void {
    if (rel_src) |rel| {
        run.addFileInput(src);
        run.addArg(rel);
    } else {
        run.addFileArg(src);
    }
}

pub fn isArchDependent(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "asmcomp/") or
        std.mem.startsWith(u8, key, "driver/opt") or
        std.mem.eql(u8, key, "file_formats/linear_format") or
        std.mem.startsWith(u8, key, "toplevel/native/");
}

pub fn concat(b: *std.Build, a: []const []const u8, c: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ a, c }) catch @panic("OOM");
}
