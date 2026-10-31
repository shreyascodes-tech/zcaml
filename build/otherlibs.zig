//! `otherlibs/`: unix, str, threads, runtime_events, dynlink, compiled with the
//! freshly built compilers, plus their C stub libraries.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const Ocamlc = @import("ocamlc.zig");
const Ocamlopt = @import("ocamlopt.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const compiler = @import("compiler.zig");
const LazyPath = std.Build.LazyPath;

pub const Artifacts = struct {
    libs: []const Lib,
    /// Also needed when compiling the native toplevel in compiler-libs.
    dynlink_dir: LazyPath,
    /// Public C headers, installed into `lib/ocaml/caml/`.
    headers: []const Header,
};

pub const Lib = struct {
    /// Install directory under `lib/ocaml/`.
    name: []const u8,
    dir: LazyPath,
    stubs: ?Stubs = null,
};

pub const Stubs = struct {
    /// Bytecode stub library name, e.g. `unixbyt` (`libunixbyt.a`, `dllunixbyt.so`).
    byt_name: []const u8,
    static_byt: *std.Build.Step.Compile,
    static_nat: *std.Build.Step.Compile,
    /// For `ocamlrun` to load at runtime; `null` where unsupported.
    shared_byt: ?*std.Build.Step.Compile,

    pub fn dllName(self: Stubs, p: Platform) []const u8 {
        return self.static_byt.step.owner.fmt("dll{s}.{s}", .{ self.byt_name, p.dllExt() });
    }
};

pub const Header = struct {
    source: LazyPath,
    dest_name: []const u8,
};

pub const Options = struct {
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    compiler: compiler.Artifacts,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(src: *const Source, options: Options) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const ol = m.otherlibs;
    const p = options.target_rt.platform;
    const ctx: Ctx = .{ .src = src, .options = options };

    // C stubs
    const unix_c = prefixed(b, "otherlibs/unix", &.{ ol.unix_common_c_sources, if (p.is_windows) ol.unix_win32_c_sources else ol.unix_unix_c_sources });
    const unix_stubs = ctx.buildStubs("unix", "otherlibs/unix", unix_c, &.{"-DCAML_BUILDING_UNIX"}, &.{"m"});
    const str_stubs = ctx.buildStubs("camlstr", "otherlibs/str", prefixed(b, "otherlibs/str", &.{ol.str_c_sources}), &.{}, &.{});
    const re_stubs = ctx.buildStubs("camlruntime_events", "otherlibs/runtime_events", prefixed(b, "otherlibs/runtime_events", &.{ol.runtime_events_c_sources}), &.{}, &.{});
    const threads_stubs = ctx.buildStubs("threads", "otherlibs/systhreads", &.{"otherlibs/systhreads/st_stubs.c"}, &.{}, &.{"pthread"});

    // Public headers
    var headers: std.ArrayList(Header) = .empty;
    for (ol.unix_headers) |h| headers.append(b.allocator, .{
        .source = src.path(b.fmt("otherlibs/unix/{s}", .{h})),
        .dest_name = std.fs.path.basename(h),
    }) catch @panic("OOM");
    for (ol.runtime_events_headers) |h| headers.append(b.allocator, .{
        .source = src.path(b.fmt("otherlibs/runtime_events/{s}", .{h})),
        .dest_name = std.fs.path.basename(h),
    }) catch @panic("OOM");
    headers.append(b.allocator, .{ .source = src.path(ol.threads_header), .dest_name = "threads.h" }) catch @panic("OOM");

    // OCaml libraries
    const unix = ctx.unixLib(unix_stubs);
    const dynlink = ctx.dynlinkLib();
    const libs = b.allocator.dupe(Lib, &.{
        .{ .name = "dynlink", .dir = dynlink },
        .{ .name = "unix", .dir = unix, .stubs = unix_stubs },
        .{ .name = "str", .dir = ctx.singleModuleLib("str", "otherlibs/str", "str", str_stubs), .stubs = str_stubs },
        .{ .name = "threads", .dir = ctx.threadsLib(unix, threads_stubs), .stubs = threads_stubs },
        .{ .name = "runtime_events", .dir = ctx.singleModuleLib("runtime_events", "otherlibs/runtime_events", "runtime_events", re_stubs), .stubs = re_stubs },
    }) catch @panic("OOM");

    return .{ .libs = libs, .dynlink_dir = dynlink, .headers = headers.items };
}

const Ctx = struct {
    src: *const Source,
    options: Options,

    fn ocamlc(self: Ctx) Ocamlc {
        return self.options.compiler.ocamlc;
    }

    fn platform(self: Ctx) Platform {
        return self.options.target_rt.platform;
    }

    fn flags(self: Ctx, base: []const []const u8, extra: []const []const u8) []const []const u8 {
        return Ocamlc.concat(self.src.b, base, extra);
    }

    /// `-dllib -l<lib> -cclib -l<lib>`
    fn stubLinkFlags(self: Ctx, stubs: Stubs) []const []const u8 {
        const b = self.src.b;
        const clib = b.fmt("-l{s}", .{stubs.byt_name});
        return b.allocator.dupe([]const u8, &.{ "-dllib", clib, "-cclib", clib }) catch @panic("OOM");
    }

    fn cma(self: Ctx, name: []const u8, objs: []const LazyPath, includes: []const LazyPath, extra: []const []const u8) LazyPath {
        return self.ocamlc().archive(name, objs, .{
            .includes = includes,
            .flags = self.flags(&.{ "-g", "-linkall" }, extra),
        });
    }

    fn nativeImpl(self: Ctx, wf: *std.Build.Step.WriteFile, ml: LazyPath, name: []const u8, cmi: LazyPath, includes: []const LazyPath, compflags: []const []const u8) Ocamlopt.Impl {
        const b = self.src.b;
        const impl = self.options.compiler.ocamlopt.impl(ml, name, cmi, .{ .includes = includes, .flags = compflags });
        _ = wf.addCopyFile(impl.cmx, b.fmt("{s}.cmx", .{name}));
        _ = wf.addCopyFile(impl.obj, b.fmt("{s}.o", .{name}));
        return impl;
    }

    /// Record relocatable stub names in the archive; locate their build outputs
    /// explicitly while linking plugins (the install tree does not exist yet).
    fn nativeArchive(self: Ctx, wf: *std.Build.Step.WriteFile, name: []const u8, cmxs: []const LazyPath, stubs: ?Stubs, shared: bool) void {
        const b = self.src.b;
        const opt = self.options.compiler.ocamlopt;
        var link_flags: std.ArrayList([]const u8) = .empty;
        link_flags.appendSlice(b.allocator, &.{ "-g", "-linkall" }) catch @panic("OOM");
        var includes: std.ArrayList(LazyPath) = .empty;
        if (stubs) |s| {
            link_flags.appendSlice(b.allocator, &.{ "-cclib", b.fmt("-l{s}", .{s.static_nat.name}) }) catch @panic("OOM");
            includes.append(b.allocator, s.static_nat.getEmittedBin().dirname()) catch @panic("OOM");
            for (self.platform().c.libs) |lib| {
                link_flags.appendSlice(b.allocator, &.{ "-cclib", b.fmt("-l{s}", .{lib}) }) catch @panic("OOM");
            }
        }
        const archive = opt.archive(name, cmxs, .{ .flags = link_flags.items });
        _ = wf.addCopyFile(archive.cmxa, b.fmt("{s}.cmxa", .{name}));
        _ = wf.addCopyFile(archive.lib, b.fmt("{s}.a", .{name}));
        if (shared) {
            _ = wf.addCopyFile(opt.shared(name, archive.cmxa, .{ .includes = includes.items }), b.fmt("{s}.cmxs", .{name}));
        }
    }

    /// A library made of one module (`str`, `runtime_events`).
    fn singleModuleLib(self: Ctx, name: []const u8, dir: []const u8, module: []const u8, stubs: Stubs) LazyPath {
        const b = self.src.b;
        const compflags = self.src.manifest.otherlibs.compflags;
        const wf = b.addWriteFiles();
        _ = wf.add("META", self.src.renderMeta(b.fmt("{s}/META.in", .{dir}), &.{}));

        const mli = self.src.path(b.fmt("{s}/{s}.mli", .{ dir, module }));
        const ml = self.src.path(b.fmt("{s}/{s}.ml", .{ dir, module }));
        const i = self.ocamlc().intf(mli, module, .{ .flags = compflags });
        const o = self.ocamlc().impl(ml, module, i.cmi, .{ .includes = &.{i.cmi.dirname()}, .flags = compflags });
        const lib = self.cma(b.fmt("{s}.cma", .{name}), &.{o.cmo}, &.{i.cmi.dirname()}, self.stubLinkFlags(stubs));

        _ = wf.addCopyFile(lib, b.fmt("{s}.cma", .{name}));
        installModule(b, wf, module, i, o, mli);
        if (self.platform().hasNativeCompiler()) {
            const native = self.nativeImpl(wf, ml, module, i.cmi, &.{i.cmi.dirname()}, compflags);
            self.nativeArchive(wf, name, &.{native.cmx}, stubs, true);
        }
        return wf.getDirectory();
    }

    fn unixLib(self: Ctx, stubs: Stubs) LazyPath {
        const b = self.src.b;
        const p = self.platform();
        const compflags = self.flags(self.src.manifest.otherlibs.compflags, &.{"-nolabels"});
        const o = self.ocamlc();
        const wf = b.addWriteFiles();
        _ = wf.add("META", self.src.renderMeta("otherlibs/unix/META.in", &.{}));

        const unix_mli = self.src.path("otherlibs/unix/unix.mli");
        const labels_mli = self.src.path("otherlibs/unix/unixLabels.mli");

        const unix_i = o.intf(unix_mli, "unix", .{ .flags = compflags });
        const unix_o = o.impl(self.src.path(b.fmt("otherlibs/unix/unix_{s}.ml", .{p.unixOrWin32()})), "unix", unix_i.cmi, .{
            .includes = &.{unix_i.cmi.dirname()},
            .flags = compflags,
        });
        const labels_i = o.intf(self.options.stdlib.expanded_dir.path(b, "otherlibs/unix/unixLabels.mli"), "unixLabels", .{
            .includes = &.{unix_i.cmi.dirname()},
            .flags = compflags,
        });
        const labels_o = o.impl(self.src.path("otherlibs/unix/unixLabels.ml"), "unixLabels", labels_i.cmi, .{
            .includes = &.{ unix_i.cmi.dirname(), labels_i.cmi.dirname() },
            .flags = compflags,
        });

        const link_flags = if (p.is_windows)
            self.flags(self.stubLinkFlags(stubs), &.{ "-cclib", "-lws2_32", "-cclib", "-ladvapi32" })
        else
            self.stubLinkFlags(stubs);
        const lib = self.cma("unix.cma", &.{ unix_o.cmo, labels_o.cmo }, &.{ unix_i.cmi.dirname(), labels_i.cmi.dirname() }, link_flags);

        _ = wf.addCopyFile(lib, "unix.cma");
        installModule(b, wf, "unix", unix_i, unix_o, unix_mli);
        installModule(b, wf, "unixLabels", labels_i, labels_o, labels_mli);
        if (p.hasNativeCompiler()) {
            const unix_n = self.nativeImpl(wf, self.src.path(b.fmt("otherlibs/unix/unix_{s}.ml", .{p.unixOrWin32()})), "unix", unix_i.cmi, &.{unix_i.cmi.dirname()}, compflags);
            const labels_n = self.nativeImpl(wf, self.src.path("otherlibs/unix/unixLabels.ml"), "unixLabels", labels_i.cmi, &.{ unix_i.cmi.dirname(), labels_i.cmi.dirname(), unix_n.cmx.dirname() }, compflags);
            self.nativeArchive(wf, "unix", &.{ unix_n.cmx, labels_n.cmx }, stubs, true);
        }
        return wf.getDirectory();
    }

    fn threadsLib(self: Ctx, unix_cmi_dir: LazyPath, stubs: Stubs) LazyPath {
        const b = self.src.b;
        const compflags = self.src.manifest.otherlibs.systhreads_compflags;
        const o = self.ocamlc();
        const wf = b.addWriteFiles();
        _ = wf.add("META", self.src.renderMeta("otherlibs/systhreads/META.in", &.{}));

        const thread_mli = self.src.path("otherlibs/systhreads/thread.mli");
        const event_mli = self.src.path("otherlibs/systhreads/event.mli");

        const thread_i = o.intf(thread_mli, "thread", .{ .includes = &.{unix_cmi_dir}, .flags = compflags });
        const event_i = o.intf(event_mli, "event", .{ .includes = &.{unix_cmi_dir}, .flags = compflags });
        const all_dirs: []const LazyPath = &.{ unix_cmi_dir, thread_i.cmi.dirname(), event_i.cmi.dirname() };
        const thread_o = o.impl(self.src.path("otherlibs/systhreads/thread.ml"), "thread", thread_i.cmi, .{ .includes = all_dirs[0..2], .flags = compflags });
        const event_o = o.impl(self.src.path("otherlibs/systhreads/event.ml"), "event", event_i.cmi, .{ .includes = all_dirs, .flags = compflags });

        const lib = self.cma("threads.cma", &.{ thread_o.cmo, event_o.cmo }, all_dirs, self.stubLinkFlags(stubs));
        _ = wf.addCopyFile(lib, "threads.cma");
        installModule(b, wf, "thread", thread_i, thread_o, thread_mli);
        installModule(b, wf, "event", event_i, event_o, event_mli);
        if (self.platform().hasNativeCompiler()) {
            const thread_n = self.nativeImpl(wf, self.src.path("otherlibs/systhreads/thread.ml"), "thread", thread_i.cmi, all_dirs, compflags);
            const event_n = self.nativeImpl(wf, self.src.path("otherlibs/systhreads/event.ml"), "event", event_i.cmi, Ocamlc.concatPaths(b, all_dirs, &.{thread_n.cmx.dirname()}), compflags);
            self.nativeArchive(wf, "threads", &.{ thread_n.cmx, event_n.cmx }, stubs, false);
        }
        return wf.getDirectory();
    }

    fn dynlinkLib(self: Ctx) LazyPath {
        const b = self.src.b;
        const m = self.src.manifest;
        const p = self.platform();
        const o = self.ocamlc();
        const wf = b.addWriteFiles();
        _ = wf.add("META", self.src.renderMeta("otherlibs/dynlink/META.in", &.{
            .{ .name = "natdynlink_archive", .value = if (p.hasNativeCompiler()) "dynlink.cmxa" else "" },
        }));

        var dl: DynlinkChain = .{ .ctx = self, .flags = self.flags(m.otherlibs.compflags, &.{ "-w", "-40" }) };
        if (m.features.dynlink_standalone) {
            const magic = m.version.magic.?;
            const cfg_ml = b.addWriteFiles().add("dynlink_config.ml", self.src.renderAt("otherlibs/dynlink/dynlink_config.ml.in", &.{
                .{ .name = "configure_input", .value = "Generated by zcaml" },
                .{ .name = "MAGIC_LENGTH", .value = b.fmt("{d}", .{magic.exec_length}) },
                .{ .name = "QS", .value = "" },
                .{ .name = "SO", .value = p.dllExt() },
                .{ .name = "CMO_MAGIC_NUMBER", .value = magic.numbers.cmo },
                .{ .name = "CMA_MAGIC_NUMBER", .value = magic.numbers.cma },
                .{ .name = "CMXS_MAGIC_NUMBER", .value = magic.numbers.cmxs },
                .{ .name = "bytecode_runtime_id", .value = p.runtimeId(b, m.version), .version_specific = true },
                .{ .name = "target", .value = p.triplet, .version_specific = true },
            }));
            _ = dl.intfOnly("file_formats/cmo_format.mli", "dynlink_cmo_format");
            _ = dl.intfOnly("file_formats/cmxs_format.mli", "dynlink_cmxs_format");
            dl.module(self.src.path("otherlibs/dynlink/dynlink_config.mli"), cfg_ml, "dynlink_config");
        } else {
            dl.flags = self.flags(m.otherlibs.compflags, &.{ "-w", "-40-66-70" });
            const packed_cmo = self.packCompilerlibs();
            dl.addInclude(packed_cmo.dirname());
            dl.cmos.append(b.allocator, packed_cmo) catch @panic("OOM");
        }

        const dir = "otherlibs/dynlink/";
        dl.module(self.src.path(dir ++ "dynlink_types.mli"), self.src.path(dir ++ "dynlink_types.ml"), "dynlink_types");
        dl.module(self.src.path(dir ++ "dynlink_platform_intf.ml"), self.src.path(dir ++ "dynlink_platform_intf.ml"), "dynlink_platform_intf");
        dl.module(self.src.path(dir ++ "dynlink_common.mli"), self.src.path(dir ++ "dynlink_common.ml"), "dynlink_common");
        if (m.features.dynlink_standalone) {
            dl.module(self.src.path(dir ++ "byte/dynlink_symtable.mli"), self.src.path(dir ++ "byte/dynlink_symtable.ml"), "dynlink_symtable");
        }
        const dynlink_mli = self.src.path(dir ++ "dynlink.mli");
        dl.module(dynlink_mli, self.src.path(dir ++ "byte/dynlink.ml"), "dynlink");

        const lib = o.archive("dynlink.cma", dl.cmos.items, .{ .includes = dl.includes.items, .flags = &.{ "-g", "-linkall" } });
        _ = wf.addCopyFile(lib, "dynlink.cma");
        installModule(b, wf, "dynlink", dl.last_intf, dl.last_impl, dynlink_mli);
        if (p.hasNativeCompiler()) {
            for (dl.native_impls.items) |n| {
                _ = wf.addCopyFile(n.impl.cmx, b.fmt("{s}.cmx", .{n.name}));
                _ = wf.addCopyFile(n.impl.obj, b.fmt("{s}.o", .{n.name}));
            }
            self.nativeArchive(wf, "dynlink", dl.cmxs.items, null, true);
        }
        return wf.getDirectory();
    }

    /// OCaml < 5.3: the compiler modules dynlink needs, packed as `Dynlink_compilerlibs`.
    /// Returns `dynlink_compilerlibs.cmo` (its `.cmi` is next to it).
    fn packCompilerlibs(self: Ctx) LazyPath {
        const b = self.src.b;
        const m = self.src.manifest;
        const o = self.ocamlc();
        const compiled = o.compilePlan(m.otherlibs.dynlink_pack, self.options.compiler.sources, .{
            .flags = self.flags(m.otherlibs.compflags, &.{ "-for-pack", "Dynlink_compilerlibs", "-w", "-40-66-70" }),
        });
        // -pack expects every .cmi next to its .cmo
        const stage = b.addWriteFiles();
        var cmos: std.ArrayList(LazyPath) = .empty;
        for (compiled.impls.values()) |u| {
            _ = stage.addCopyFile(compiled.intfs.get(u.unit.key).?.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
            cmos.append(b.allocator, stage.addCopyFile(u.impl.cmo, b.fmt("{s}.cmo", .{u.unit.name}))) catch @panic("OOM");
        }
        return o.link("dynlink_compilerlibs.cmo", cmos.items, .{ .flags = &.{ "-g", "-pack" } });
    }

    /// Build a static + shared stub library pair from C sources under `dir`.
    fn buildStubs(
        self: Ctx,
        base_name: []const u8,
        dir: []const u8,
        c_files: []const []const u8,
        extra_cflags: []const []const u8,
        shared_libs: []const []const u8,
    ) Stubs {
        const b = self.src.b;
        const p = self.platform();
        const optimize = self.options.optimize;

        const has_suffix = self.src.manifest.features.byt_stub_suffix and !std.mem.eql(u8, base_name, "threads");
        const byt_name = if (has_suffix) b.fmt("{s}byt", .{base_name}) else base_name;
        const nat_name = b.fmt("{s}nat", .{base_name});

        const byt_cflags = p.c.flags(b, Ocamlc.concat(b, &.{
            "-fno-common",
            "-DCAMLDLLIMPORT=",
            "-Wno-unused-parameter",
            "-Wno-sign-compare",
        }, extra_cflags));
        const nat_cflags = Ocamlc.concat(b, byt_cflags, p.nativeDefines(b));

        const lib = struct {
            fn make(
                ctx: Ctx,
                name: []const u8,
                linkage: std.builtin.LinkMode,
                sub: []const u8,
                files: []const []const u8,
                cflags: []const []const u8,
                opt: std.builtin.OptimizeMode,
            ) *std.Build.Step.Compile {
                const bb = ctx.src.b;
                const l = bb.addLibrary(.{
                    .linkage = linkage,
                    .name = name,
                    .root_module = runtime.cModule(bb, ctx.platform(), opt, .{ .pic = true }),
                });
                const mod = l.root_module;
                ctx.options.target_rt.addIncludes(ctx.src.*, mod);
                mod.addIncludePath(ctx.src.path("otherlibs/unix"));
                mod.addIncludePath(ctx.src.path("otherlibs/unix/caml"));
                mod.addIncludePath(ctx.src.path(sub));
                mod.addIncludePath(ctx.src.path(bb.fmt("{s}/caml", .{sub})));
                mod.addCSourceFiles(.{ .root = ctx.src.path(""), .files = files, .flags = cflags });
                return l;
            }
        }.make;

        const shared: ?*std.Build.Step.Compile = if (!p.is_windows) blk: {
            const dll = lib(self, byt_name, .dynamic, dir, c_files, byt_cflags, optimize);
            dll.linker_allow_shlib_undefined = true;
            for (shared_libs) |l| dll.root_module.linkSystemLibrary(l, .{});
            break :blk dll;
        } else null;

        return .{
            .byt_name = byt_name,
            .static_byt = lib(self, byt_name, .static, dir, c_files, byt_cflags, optimize),
            .static_nat = lib(self, nat_name, .static, dir, c_files, nat_cflags, optimize),
            .shared_byt = shared,
        };
    }
};

/// Compiles dynlink's modules in order, each seeing the interfaces of all previous ones.
const DynlinkChain = struct {
    ctx: Ctx,
    flags: []const []const u8,
    includes: std.ArrayList(LazyPath) = .empty,
    cmos: std.ArrayList(LazyPath) = .empty,
    cmxs: std.ArrayList(LazyPath) = .empty,
    native_impls: std.ArrayList(struct { name: []const u8, impl: Ocamlopt.Impl }) = .empty,
    last_intf: Ocamlc.Intf = undefined,
    last_impl: Ocamlc.Impl = undefined,

    fn addInclude(self: *DynlinkChain, dir: LazyPath) void {
        self.includes.append(self.ctx.src.b.allocator, dir) catch @panic("OOM");
    }

    fn intfOnly(self: *DynlinkChain, mli: []const u8, name: []const u8) Ocamlc.Intf {
        const i = self.ctx.ocamlc().intf(self.ctx.src.path(mli), name, .{ .includes = self.includes.items, .flags = self.flags });
        self.addInclude(i.cmi.dirname());
        return i;
    }

    fn module(self: *DynlinkChain, mli: LazyPath, ml: LazyPath, name: []const u8) void {
        const o = self.ctx.ocamlc();
        const i = o.intf(mli, name, .{ .includes = self.includes.items, .flags = self.flags });
        self.addInclude(i.cmi.dirname());
        const impl = o.impl(ml, name, i.cmi, .{ .includes = self.includes.items, .flags = self.flags });
        self.cmos.append(self.ctx.src.b.allocator, impl.cmo) catch @panic("OOM");
        if (self.ctx.platform().hasNativeCompiler() and !std.mem.eql(u8, name, "dynlink_symtable")) {
            const native_ml = if (std.mem.eql(u8, name, "dynlink")) self.ctx.src.path("otherlibs/dynlink/native/dynlink.ml") else ml;
            const native = self.ctx.options.compiler.ocamlopt.impl(native_ml, name, i.cmi, .{ .includes = self.includes.items, .flags = self.flags });
            self.cmxs.append(self.ctx.src.b.allocator, native.cmx) catch @panic("OOM");
            self.native_impls.append(self.ctx.src.b.allocator, .{ .name = name, .impl = native }) catch @panic("OOM");
            self.addInclude(native.cmx.dirname());
        }
        self.last_intf = i;
        self.last_impl = impl;
    }
};

/// `<name>.{cmi,cmti,cmt,mli}`
fn installModule(b: *std.Build, wf: *std.Build.Step.WriteFile, name: []const u8, i: Ocamlc.Intf, o: Ocamlc.Impl, mli: LazyPath) void {
    _ = wf.addCopyFile(i.cmi, b.fmt("{s}.cmi", .{name}));
    _ = wf.addCopyFile(i.cmti, b.fmt("{s}.cmti", .{name}));
    _ = wf.addCopyFile(o.cmt, b.fmt("{s}.cmt", .{name}));
    _ = wf.addCopyFile(mli, b.fmt("{s}.mli", .{name}));
}

fn prefixed(b: *std.Build, dir: []const u8, lists: []const []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lists) |list| {
        for (list) |f| out.append(b.allocator, b.fmt("{s}/{s}", .{ dir, f })) catch @panic("OOM");
    }
    return out.items;
}
