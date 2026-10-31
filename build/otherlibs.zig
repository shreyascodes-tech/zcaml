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

    fn platform(self: Ctx) Platform {
        return self.options.target_rt.platform;
    }

    fn singleModuleLib(self: Ctx, name: []const u8, dir: []const u8, module: []const u8, stubs: Stubs) LazyPath {
        const b = self.src.b;
        var lib = LibBuilder.init(self, b.fmt("{s}/META.in", .{dir}), &.{}, self.src.manifest.otherlibs.compflags);
        lib.pubModule(module, self.src.path(b.fmt("{s}/{s}.mli", .{ dir, module })), self.src.path(b.fmt("{s}/{s}.ml", .{ dir, module })));
        return lib.finish(name, stubs, &.{}, true);
    }

    fn unixLib(self: Ctx, stubs: Stubs) LazyPath {
        const b = self.src.b;
        const p = self.platform();
        const compflags = Ocamlc.concat(b, self.src.manifest.otherlibs.compflags, &.{"-nolabels"});
        var lib = LibBuilder.init(self, "otherlibs/unix/META.in", &.{}, compflags);
        lib.pubModule("unix", self.src.path("otherlibs/unix/unix.mli"), self.src.path(b.fmt("otherlibs/unix/unix_{s}.ml", .{p.unixOrWin32()})));
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
        var lib = LibBuilder.init(self, "otherlibs/systhreads/META.in", &.{}, self.src.manifest.otherlibs.systhreads_compflags);
        lib.addInclude(unix_cmi_dir);
        lib.pubModule("thread", self.src.path("otherlibs/systhreads/thread.mli"), self.src.path("otherlibs/systhreads/thread.ml"));
        lib.pubModule("event", self.src.path("otherlibs/systhreads/event.mli"), self.src.path("otherlibs/systhreads/event.ml"));
        return lib.finish("threads", stubs, &.{}, false);
    }

    fn dynlinkLib(self: Ctx) LazyPath {
        const b = self.src.b;
        const m = self.src.manifest;
        const p = self.platform();
        const magic = m.version.magic;
        const cfg_ml = b.addWriteFiles().add("dynlink_config.ml", self.src.renderAt("otherlibs/dynlink/dynlink_config.ml.in", &.{
            .{ .name = "configure_input", .value = "Generated by zcaml" },
            .{ .name = "MAGIC_LENGTH", .value = b.fmt("{d}", .{magic.exec_length}) },
            .{ .name = "QS", .value = "" },
            .{ .name = "SO", .value = p.dllExt() },
            .{ .name = "CMO_MAGIC_NUMBER", .value = magic.numbers.cmo },
            .{ .name = "CMA_MAGIC_NUMBER", .value = magic.numbers.cma },
            .{ .name = "CMXS_MAGIC_NUMBER", .value = magic.numbers.cmxs },
            .{ .name = "bytecode_runtime_id", .value = p.runtimeId(b, m.version) },
            .{ .name = "target", .value = p.triplet },
        }));

        var lib = LibBuilder.init(self, "otherlibs/dynlink/META.in", &.{
            .{ .name = "natdynlink_archive", .value = if (p.hasNativeCompiler()) "dynlink.cmxa" else "" },
        }, Ocamlc.concat(b, m.otherlibs.compflags, &.{ "-w", "-40" }));

        _ = lib.intfOnly("dynlink_cmo_format", "file_formats/cmo_format.mli");
        _ = lib.intfOnly("dynlink_cmxs_format", "file_formats/cmxs_format.mli");
        const dir = "otherlibs/dynlink/";
        lib.privModule("dynlink_config", self.src.path(dir ++ "dynlink_config.mli"), cfg_ml);
        lib.privModule("dynlink_types", self.src.path(dir ++ "dynlink_types.mli"), self.src.path(dir ++ "dynlink_types.ml"));
        lib.privModule("dynlink_platform_intf", self.src.path(dir ++ "dynlink_platform_intf.ml"), self.src.path(dir ++ "dynlink_platform_intf.ml"));
        lib.privModule("dynlink_common", self.src.path(dir ++ "dynlink_common.mli"), self.src.path(dir ++ "dynlink_common.ml"));
        lib.add("dynlink_symtable", self.src.path(dir ++ "byte/dynlink_symtable.mli"), null, self.src.path(dir ++ "byte/dynlink_symtable.ml"), null);
        const dynlink_mli = self.src.path(dir ++ "dynlink.mli");
        lib.add("dynlink", dynlink_mli, dynlink_mli, self.src.path(dir ++ "byte/dynlink.ml"), self.src.path(dir ++ "native/dynlink.ml"));
        return lib.finish("dynlink", null, &.{}, true);
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

        const byt_name = if (!std.mem.eql(u8, base_name, "threads")) b.fmt("{s}byt", .{base_name}) else base_name;
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

/// Compiles a library's modules in order (each seeing all previous interfaces/implementations)
/// and assembles its install directory (`META`, `.cma`, `.cmxa`, `.a`, `.cmxs`, `.cmi`, ...).
const LibBuilder = struct {
    ctx: Ctx,
    wf: *std.Build.Step.WriteFile,
    flags: []const []const u8,
    byte_includes: std.ArrayList(LazyPath) = .empty,
    nat_includes: std.ArrayList(LazyPath) = .empty,
    cmos: std.ArrayList(LazyPath) = .empty,
    cmxs: std.ArrayList(LazyPath) = .empty,

    fn init(ctx: Ctx, meta_in: []const u8, meta_vars: []const Source.Var, flags: []const []const u8) LibBuilder {
        const wf = ctx.src.b.addWriteFiles();
        _ = wf.add("META", ctx.src.renderMeta(meta_in, meta_vars));
        return .{ .ctx = ctx, .wf = wf, .flags = flags };
    }

    fn addInclude(self: *LibBuilder, dir: LazyPath) void {
        const gpa = self.ctx.src.b.allocator;
        self.byte_includes.append(gpa, dir) catch @panic("OOM");
        self.nat_includes.append(gpa, dir) catch @panic("OOM");
    }

    fn intfOnly(self: *LibBuilder, name: []const u8, mli_rel: []const u8) Ocamlc.Intf {
        const i = self.ctx.options.compiler.ocamlc.intf(self.ctx.src.path(mli_rel), name, .{
            .includes = self.byte_includes.items,
            .flags = self.flags,
        });
        self.addInclude(i.cmi.dirname());
        return i;
    }

    fn pubModule(self: *LibBuilder, name: []const u8, mli: LazyPath, ml: LazyPath) void {
        self.add(name, mli, mli, ml, ml);
    }

    fn privModule(self: *LibBuilder, name: []const u8, mli: LazyPath, ml: LazyPath) void {
        self.add(name, mli, null, ml, ml);
    }

    fn add(
        self: *LibBuilder,
        name: []const u8,
        mli: LazyPath,
        installed_mli: ?LazyPath,
        byte_ml: LazyPath,
        native_ml: ?LazyPath,
    ) void {
        const b = self.ctx.src.b;
        const ocamlc = self.ctx.options.compiler.ocamlc;
        const i = ocamlc.intf(mli, name, .{ .includes = self.byte_includes.items, .flags = self.flags });
        self.addInclude(i.cmi.dirname());
        const o = ocamlc.impl(byte_ml, name, i.cmi, .{ .includes = self.byte_includes.items, .flags = self.flags });
        self.cmos.append(b.allocator, o.cmo) catch @panic("OOM");

        if (installed_mli) |pub_mli| {
            _ = self.wf.addCopyFile(i.cmi, b.fmt("{s}.cmi", .{name}));
            _ = self.wf.addCopyFile(i.cmti, b.fmt("{s}.cmti", .{name}));
            _ = self.wf.addCopyFile(o.cmt, b.fmt("{s}.cmt", .{name}));
            _ = self.wf.addCopyFile(pub_mli, b.fmt("{s}.mli", .{name}));
        }

        if (self.ctx.platform().hasNativeCompiler()) {
            if (native_ml) |n_ml| {
                const n = self.ctx.options.compiler.ocamlopt.impl(n_ml, name, i.cmi, .{
                    .includes = self.nat_includes.items,
                    .flags = self.flags,
                });
                _ = self.wf.addCopyFile(n.cmx, b.fmt("{s}.cmx", .{name}));
                _ = self.wf.addCopyFile(n.obj, b.fmt("{s}.o", .{name}));
                self.cmxs.append(b.allocator, n.cmx) catch @panic("OOM");
                self.nat_includes.append(b.allocator, n.cmx.dirname()) catch @panic("OOM");
            }
        }
    }

    fn finish(self: *LibBuilder, name: []const u8, stubs: ?Stubs, extra_byte_flags: []const []const u8, shared: bool) LazyPath {
        const b = self.ctx.src.b;
        var byte_flags: std.ArrayList([]const u8) = .empty;
        byte_flags.appendSlice(b.allocator, &.{ "-g", "-linkall" }) catch @panic("OOM");
        if (stubs) |s| {
            const clib = b.fmt("-l{s}", .{s.byt_name});
            byte_flags.appendSlice(b.allocator, &.{ "-dllib", clib, "-cclib", clib }) catch @panic("OOM");
        }
        byte_flags.appendSlice(b.allocator, extra_byte_flags) catch @panic("OOM");

        const cma_name = b.fmt("{s}.cma", .{name});
        const cma = self.ctx.options.compiler.ocamlc.archive(cma_name, self.cmos.items, .{
            .includes = self.byte_includes.items,
            .flags = byte_flags.items,
        });
        _ = self.wf.addCopyFile(cma, cma_name);

        if (self.ctx.platform().hasNativeCompiler()) {
            const opt = self.ctx.options.compiler.ocamlopt;
            var nat_flags: std.ArrayList([]const u8) = .empty;
            nat_flags.appendSlice(b.allocator, &.{ "-g", "-linkall" }) catch @panic("OOM");
            var plugin_includes: std.ArrayList(LazyPath) = .empty;
            if (stubs) |s| {
                nat_flags.appendSlice(b.allocator, &.{ "-cclib", b.fmt("-l{s}", .{s.static_nat.name}) }) catch @panic("OOM");
                plugin_includes.append(b.allocator, s.static_nat.getEmittedBin().dirname()) catch @panic("OOM");
                for (self.ctx.platform().c.libs) |lib| {
                    nat_flags.appendSlice(b.allocator, &.{ "-cclib", b.fmt("-l{s}", .{lib}) }) catch @panic("OOM");
                }
            }
            const archive = opt.archive(name, self.cmxs.items, .{ .flags = nat_flags.items });
            _ = self.wf.addCopyFile(archive.cmxa, b.fmt("{s}.cmxa", .{name}));
            _ = self.wf.addCopyFile(archive.lib, b.fmt("{s}.a", .{name}));
            if (shared) {
                _ = self.wf.addCopyFile(opt.shared(name, archive.cmxa, .{ .includes = plugin_includes.items }), b.fmt("{s}.cmxs", .{name}));
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
