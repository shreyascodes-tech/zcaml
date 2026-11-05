//! `otherlibs/`: unix, str, threads, runtime_events, dynlink, compiled with the
//! freshly built compilers, plus their C stub libraries.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const driver = @import("driver.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const configure = @import("configure.zig");
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    target_rt: runtime.Artifacts,
    stdlib: stdlib.Artifacts,
    ocamlc: Ocamlc,
    ocamlopt: Ocamlopt,
};

pub const Artifacts = struct {
    libs: []const Lib,
    /// Also needed when compiling the native toplevel, debugger, and ocamldoc.
    dynlink_dir: LazyPath,
    unix_dir: LazyPath,
    str_dir: LazyPath,
    unix_stubs: Stubs,
    str_stubs: Stubs,
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
    /// Contains `static_nat` as `lib<name>.a`.
    static_nat_dir: LazyPath,
    /// For `ocamlrun` to load at runtime; `null` where unsupported.
    shared_byt: ?LazyPath,

    pub fn dllName(self: Stubs, p: Platform) []const u8 {
        return self.static_byt.step.owner.fmt("dll{s}.{s}", .{ self.byt_name, p.dllExt() });
    }
};

pub const Header = struct {
    source: LazyPath,
    dest_name: []const u8,
};

pub fn build(src: *const Source, options: Options) Artifacts {
    const b = src.b;
    const m = src.manifest;
    const ol = m.otherlibs;
    const p = options.target_rt.platform;
    const ctx: Ctx = .{ .src = src, .options = options };

    const unix_c = prefixed(b, "otherlibs/unix", &.{ ol.unix_common_c_sources, if (p.is_windows) ol.unix_win32_c_sources else ol.unix_unix_c_sources });
    const unix_stubs = ctx.buildStubs("unix", "otherlibs/unix", unix_c, &.{"-DCAML_BUILDING_UNIX"}, if (p.is_windows) p.c.libs else &.{"m"});
    const str_stubs = ctx.buildStubs("camlstr", "otherlibs/str", prefixed(b, "otherlibs/str", &.{ol.str_c_sources}), &.{}, &.{});
    const re_stubs = ctx.buildStubs("camlruntime_events", "otherlibs/runtime_events", prefixed(b, "otherlibs/runtime_events", &.{ol.runtime_events_c_sources}), &.{}, &.{});
    const threads_stubs = ctx.buildStubs("threads", "otherlibs/systhreads", &.{"otherlibs/systhreads/st_stubs.c"}, &.{}, if (p.is_windows) p.c.libs else &.{"pthread"});

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

    const unix = ctx.unixLib(unix_stubs);
    const str = ctx.singleModuleLib("str", "otherlibs/str", "str", str_stubs);
    const dynlink = ctx.dynlinkLib();
    const libs = b.allocator.dupe(Lib, &.{
        .{ .name = "dynlink", .dir = dynlink },
        .{ .name = "unix", .dir = unix, .stubs = unix_stubs },
        .{ .name = "str", .dir = str, .stubs = str_stubs },
        .{ .name = "threads", .dir = ctx.threadsLib(unix, threads_stubs), .stubs = threads_stubs },
        .{ .name = "runtime_events", .dir = ctx.singleModuleLib("runtime_events", "otherlibs/runtime_events", "runtime_events", re_stubs), .stubs = re_stubs },
    }) catch @panic("OOM");

    return .{
        .libs = libs,
        .dynlink_dir = dynlink,
        .unix_dir = unix,
        .str_dir = str,
        .unix_stubs = unix_stubs,
        .str_stubs = str_stubs,
        .headers = headers.items,
    };
}

const Ctx = struct {
    src: *const Source,
    options: Options,

    fn platform(self: Ctx) Platform {
        return self.options.target_rt.platform;
    }

    fn singleModuleLib(self: Ctx, name: []const u8, dir: []const u8, module: []const u8, stubs: Stubs) LazyPath {
        const b = self.src.b;
        var lib = LibBuilder.init(self, dir, b.fmt("{s}/META.in", .{dir}), &.{}, self.src.manifest.otherlibs.compflags);
        lib.pubModule(module, self.src.path(b.fmt("{s}/{s}.mli", .{ dir, module })), self.src.path(b.fmt("{s}/{s}.ml", .{ dir, module })));
        return lib.finish(name, stubs, &.{}, true);
    }

    fn unixLib(self: Ctx, stubs: Stubs) LazyPath {
        const b = self.src.b;
        const p = self.platform();
        const compflags = driver.concat(b, self.src.manifest.otherlibs.compflags, &.{"-nolabels"});
        var lib = LibBuilder.init(self, "otherlibs/unix", "otherlibs/unix/META.in", &.{}, compflags);
        lib.pubModule("unix", self.src.path("otherlibs/unix/unix.mli"), self.src.path(if (p.is_windows) "otherlibs/unix/unix_win32.ml" else "otherlibs/unix/unix_unix.ml"));
        const labels_ml = self.src.path("otherlibs/unix/unixLabels.ml");
        lib.add(
            "unixLabels",
            self.options.stdlib.expanded_dir.path(b, "otherlibs/unix/unixLabels.mli"),
            self.src.path("otherlibs/unix/unixLabels.mli"),
            labels_ml,
            labels_ml,
        );
        const extra_byte = if (p.is_windows) &[_][]const u8{ "-cclib", "-lws2_32", "-cclib", "-ladvapi32" } else &.{};
        return lib.finish("unix", stubs, extra_byte, true);
    }

    fn threadsLib(self: Ctx, unix_cmi_dir: LazyPath, stubs: Stubs) LazyPath {
        var lib = LibBuilder.init(self, "otherlibs/systhreads", "otherlibs/systhreads/META.in", &.{}, self.src.manifest.otherlibs.systhreads_compflags);
        lib.addInclude(unix_cmi_dir);
        lib.pubModule("thread", self.src.path("otherlibs/systhreads/thread.mli"), self.src.path("otherlibs/systhreads/thread.ml"));
        lib.pubModule("event", self.src.path("otherlibs/systhreads/event.mli"), self.src.path("otherlibs/systhreads/event.ml"));
        return lib.finish("threads", stubs, &.{}, false);
    }

    fn dynlinkLib(self: Ctx) LazyPath {
        const b = self.src.b;
        const m = self.src.manifest;
        const p = self.platform();
        const cfg_ml = b.addWriteFiles().add("dynlink_config.ml", Source.namedText(b, "otherlibs/dynlink/dynlink_config.ml", configure.dynlinkConfigMl(self.src, p)));

        var lib = LibBuilder.init(self, "", "otherlibs/dynlink/META.in", &.{
            .{ .name = "natdynlink_archive", .value = if (p.hasNativeCompiler()) "dynlink.cmxa" else "" },
        }, driver.concat(b, m.otherlibs.compflags, &.{ "-w", "-40" }));

        lib.intfOnly("dynlink_cmo_format", "file_formats/cmo_format.mli");
        lib.intfOnly("dynlink_cmxs_format", "file_formats/cmxs_format.mli");
        const dir = "otherlibs/dynlink/";
        // Generated per target: other modules must not inline it.
        lib.addOpaque("dynlink_config", self.src.path(dir ++ "dynlink_config.mli"), cfg_ml);
        lib.privModule("dynlink_types", self.src.path(dir ++ "dynlink_types.mli"), self.src.path(dir ++ "dynlink_types.ml"));
        lib.privModule("dynlink_platform_intf", self.src.path(dir ++ "dynlink_platform_intf.ml"), self.src.path(dir ++ "dynlink_platform_intf.ml"));
        lib.privModule("dynlink_common", self.src.path(dir ++ "dynlink_common.mli"), self.src.path(dir ++ "dynlink_common.ml"));
        lib.add("dynlink_symtable", self.src.path(dir ++ "byte/dynlink_symtable.mli"), null, self.src.path(dir ++ "byte/dynlink_symtable.ml"), null);
        const dynlink_mli = self.src.path(dir ++ "dynlink.mli");
        lib.add("dynlink", dynlink_mli, dynlink_mli, self.src.path(dir ++ "byte/dynlink.ml"), self.src.path(dir ++ "native/dynlink.ml"));
        return lib.finish("dynlink", null, &.{}, false);
    }

    fn stubModule(self: Ctx, sub: []const u8) *std.Build.Module {
        const bb = self.src.b;
        const mod = self.platform().cModule(bb, .{ .pic = true });
        self.options.target_rt.addIncludes(self.src, mod);
        mod.addIncludePath(self.src.path("otherlibs/unix"));
        mod.addIncludePath(self.src.path("otherlibs/unix/caml"));
        mod.addIncludePath(self.src.path(sub));
        mod.addIncludePath(self.src.path(bb.fmt("{s}/caml", .{sub})));
        return mod;
    }

    fn buildStubLib(
        self: Ctx,
        name: []const u8,
        linkage: std.builtin.LinkMode,
        sub: []const u8,
        files: []const []const u8,
        cflags: []const []const u8,
    ) *std.Build.Step.Compile {
        const l = self.src.b.addLibrary(.{
            .linkage = linkage,
            .name = name,
            .root_module = self.stubModule(sub),
        });
        l.root_module.addCSourceFiles(.{ .root = self.src.path(""), .files = files, .flags = cflags });
        return l;
    }

    fn flexlinkStubDll(
        self: Ctx,
        fl: driver.Flexlink,
        name: []const u8,
        sub: []const u8,
        files: []const []const u8,
        cflags: []const []const u8,
        libs: []const []const u8,
    ) LazyPath {
        const bb = self.src.b;
        const run = fl.run(bb);
        run.addArg("-o");
        const out = run.addOutputFileArg(bb.fmt("dll{s}.dll", .{name}));
        // flexlink rewrites individual COFF objects, which `lld` cannot partially link.
        for (files) |rel| {
            const obj = bb.addObject(.{
                .name = bb.fmt("{s}_{s}", .{ name, std.fs.path.stem(rel) }),
                .root_module = self.stubModule(sub),
            });
            obj.root_module.addCSourceFile(.{ .file = self.src.path(rel), .flags = cflags });
            run.addFileArg(obj.getEmittedBin());
        }
        for (libs) |l| run.addArg(bb.fmt("-l{s}", .{l}));
        run.addArgs(&.{ "-link", "-s" });
        return out;
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

        const byt_name = if (!std.mem.eql(u8, base_name, "threads")) b.fmt("{s}byt", .{base_name}) else base_name;
        const nat_name = b.fmt("{s}nat", .{base_name});

        const byt_cflags = p.c.flags(b, driver.concat(b, &.{
            "-fno-common",
            "-DCAMLDLLIMPORT=",
            "-Wno-unused-parameter",
            "-Wno-sign-compare",
        }, extra_cflags));
        const nat_cflags = driver.concat(b, byt_cflags, p.nativeDefines(b));

        const shared: ?LazyPath = if (!p.is_windows) blk: {
            const dll = self.buildStubLib(byt_name, .dynamic, dir, c_files, byt_cflags);
            dll.linker_allow_shlib_undefined = true;
            for (shared_libs) |l| dll.root_module.linkSystemLibrary(l, .{});
            break :blk dll.getEmittedBin();
        } else if (self.options.target_rt.flexlink) |fl|
            self.flexlinkStubDll(fl, byt_name, dir, c_files, byt_cflags, shared_libs)
        else
            null;

        const static_nat = self.buildStubLib(nat_name, .static, dir, c_files, nat_cflags);
        const static_nat_wf = b.addWriteFiles();
        _ = static_nat_wf.addCopyFile(static_nat.getEmittedBin(), b.fmt("lib{s}.a", .{nat_name}));

        return .{
            .byt_name = byt_name,
            .static_byt = self.buildStubLib(byt_name, .static, dir, c_files, byt_cflags),
            .static_nat = static_nat,
            .static_nat_dir = static_nat_wf.getDirectory(),
            .shared_byt = shared,
        };
    }
};

/// Compiles a library's modules in order (each seeing all previous interfaces/implementations)
/// and assembles its install directory (`META`, `.cma`, `.cmxa`, `.a`, `.cmxs`, `.cmi`, ...).
const LibBuilder = struct {
    ctx: Ctx,
    cwd_sub: []const u8,
    wf: *std.Build.Step.WriteFile,
    flags: []const []const u8,
    byte_includes: std.ArrayList(LazyPath) = .empty,
    nat_includes: std.ArrayList(LazyPath) = .empty,
    cmos: std.ArrayList(LazyPath) = .empty,
    cmxs: std.ArrayList(LazyPath) = .empty,

    fn init(ctx: Ctx, cwd_sub: []const u8, meta_in: []const u8, meta_vars: []const Source.Var, flags: []const []const u8) LibBuilder {
        const wf = ctx.src.b.addWriteFiles();
        _ = wf.add("META", ctx.src.renderMeta(meta_in, meta_vars));
        return .{ .ctx = ctx, .cwd_sub = cwd_sub, .wf = wf, .flags = flags };
    }

    fn relSrc(self: LibBuilder, lp: LazyPath) ?[]const u8 {
        return switch (lp) {
            .dependency => |d| if (self.cwd_sub.len == 0) d.sub_path else std.fs.path.basename(d.sub_path),
            else => null,
        };
    }

    fn ocamlc(self: LibBuilder) Ocamlc {
        var c = self.ctx.options.ocamlc;
        c.cwd = self.ctx.src.path(self.cwd_sub);
        return c;
    }

    fn ocamlopt(self: LibBuilder) Ocamlopt {
        var o = self.ctx.options.ocamlopt;
        o.cwd = self.ctx.src.path(self.cwd_sub);
        return o;
    }

    fn addInclude(self: *LibBuilder, dir: LazyPath) void {
        const gpa = self.ctx.src.b.allocator;
        self.byte_includes.append(gpa, dir) catch @panic("OOM");
        self.nat_includes.append(gpa, dir) catch @panic("OOM");
    }

    fn intfOnly(self: *LibBuilder, name: []const u8, mli_rel: []const u8) void {
        const lp = self.ctx.src.path(mli_rel);
        const i = self.ocamlc().intf(lp, name, .{
            .includes = self.byte_includes.items,
            .flags = self.flags,
            .rel_src = self.relSrc(lp),
        });
        self.addInclude(i.cmi.dirname());
    }

    fn pubModule(self: *LibBuilder, name: []const u8, mli: LazyPath, ml: LazyPath) void {
        self.add(name, mli, mli, ml, ml);
    }

    fn privModule(self: *LibBuilder, name: []const u8, mli: LazyPath, ml: LazyPath) void {
        self.add(name, mli, null, ml, ml);
    }

    /// A private module compiled with `-opaque`, its `.cmx` hidden from later modules.
    fn addOpaque(self: *LibBuilder, name: []const u8, mli: LazyPath, ml: LazyPath) void {
        self.addModule(name, mli, null, ml, ml, true);
    }

    fn add(
        self: *LibBuilder,
        name: []const u8,
        mli: LazyPath,
        installed_mli: ?LazyPath,
        byte_ml: LazyPath,
        native_ml: ?LazyPath,
    ) void {
        self.addModule(name, mli, installed_mli, byte_ml, native_ml, false);
    }

    fn addModule(
        self: *LibBuilder,
        name: []const u8,
        mli: LazyPath,
        installed_mli: ?LazyPath,
        byte_ml: LazyPath,
        native_ml: ?LazyPath,
        opaque_: bool,
    ) void {
        const b = self.ctx.src.b;
        const c = self.ocamlc();
        const intf_flags = if (opaque_) driver.concat(b, self.flags, &.{"-opaque"}) else self.flags;
        const i = c.intf(mli, name, .{ .includes = self.byte_includes.items, .flags = intf_flags, .rel_src = self.relSrc(mli) });
        self.addInclude(i.cmi.dirname());
        const o = c.impl(byte_ml, name, i.cmi, .{ .includes = self.byte_includes.items, .flags = self.flags, .rel_src = self.relSrc(byte_ml) });
        self.cmos.append(b.allocator, o.cmo) catch @panic("OOM");

        if (installed_mli) |pub_mli| {
            _ = self.wf.addCopyFile(i.cmi, b.fmt("{s}.cmi", .{name}));
            _ = self.wf.addCopyFile(i.cmti, b.fmt("{s}.cmti", .{name}));
            _ = self.wf.addCopyFile(o.cmt, b.fmt("{s}.cmt", .{name}));
            _ = self.wf.addCopyFile(pub_mli, b.fmt("{s}.mli", .{name}));
        }

        if (self.ctx.platform().hasNativeCompiler()) {
            if (native_ml) |n_ml| {
                const n = self.ocamlopt().impl(n_ml, name, i.cmi, .{
                    .includes = self.nat_includes.items,
                    .flags = self.flags,
                    .rel_src = self.relSrc(n_ml),
                });
                _ = self.wf.addCopyFile(n.cmx, b.fmt("{s}.cmx", .{name}));
                self.cmxs.append(b.allocator, n.cmx) catch @panic("OOM");
                if (!opaque_) self.nat_includes.append(b.allocator, n.cmx.dirname()) catch @panic("OOM");
            }
        }
    }

    fn finish(self: *LibBuilder, name: []const u8, stubs: ?Stubs, extra_byte_flags: []const []const u8, shared: bool) LazyPath {
        const b = self.ctx.src.b;
        var byte_flags: std.ArrayList([]const u8) = .empty;
        byte_flags.append(b.allocator, "-g") catch @panic("OOM");
        if (stubs) |s| {
            byte_flags.append(b.allocator, "-linkall") catch @panic("OOM");
            const clib = b.fmt("-l{s}", .{s.byt_name});
            if (s.shared_byt != null) byte_flags.appendSlice(b.allocator, &.{ "-dllib", clib }) catch @panic("OOM");
            byte_flags.appendSlice(b.allocator, &.{ "-cclib", clib }) catch @panic("OOM");
        }
        byte_flags.appendSlice(b.allocator, extra_byte_flags) catch @panic("OOM");

        const cma_name = b.fmt("{s}.cma", .{name});
        const cma = self.ctx.options.ocamlc.archive(cma_name, self.cmos.items, .{
            .includes = self.byte_includes.items,
            .flags = byte_flags.items,
        });
        _ = self.wf.addCopyFile(cma, cma_name);

        if (self.ctx.platform().hasNativeCompiler()) {
            const opt = self.ctx.options.ocamlopt;
            var nat_flags: std.ArrayList([]const u8) = .empty;
            nat_flags.append(b.allocator, "-g") catch @panic("OOM");
            var plugin_includes: std.ArrayList(LazyPath) = .empty;
            if (stubs) |s| {
                nat_flags.append(b.allocator, "-linkall") catch @panic("OOM");
                nat_flags.appendSlice(b.allocator, &.{ "-cclib", b.fmt("-l{s}", .{s.static_nat.name}) }) catch @panic("OOM");
                plugin_includes.append(b.allocator, s.static_nat_dir) catch @panic("OOM");
                for (self.ctx.platform().c.libs) |lib| {
                    nat_flags.appendSlice(b.allocator, &.{ "-cclib", b.fmt("-l{s}", .{lib}) }) catch @panic("OOM");
                }
            }
            const archive = opt.archive(name, self.cmxs.items, .{ .flags = nat_flags.items });
            _ = self.wf.addCopyFile(archive.cmxa, b.fmt("{s}.cmxa", .{name}));
            _ = self.wf.addCopyFile(archive.lib, b.fmt("{s}.a", .{name}));
            if (shared and (!self.ctx.platform().is_windows or opt.flexlink != null)) {
                _ = self.wf.addCopyFile(opt.shared(name, archive.cmxa, .{ .includes = plugin_includes.items, .strip_debug = true }), b.fmt("{s}.cmxs", .{name}));
            }
        }

        return self.wf.getDirectory();
    }
};

fn prefixed(b: *std.Build, dir: []const u8, lists: []const []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lists) |list| {
        for (list) |f| out.append(b.allocator, b.fmt("{s}/{s}", .{ dir, f })) catch @panic("OOM");
    }
    return out.items;
}
