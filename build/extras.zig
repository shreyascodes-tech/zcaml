//! Optional tools and toplevels: `ocamldebug`, `ocamldoc`, and `ocamlnat`.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const runtime = @import("runtime.zig");
const compiler = @import("compiler.zig");
const otherlibs = @import("otherlibs.zig");
const driver = @import("driver.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const LazyPath = std.Build.LazyPath;

pub fn linkOcamlnat(
    b: *std.Build,
    arch_byte: compiler.ArchByte,
    arch_nat: compiler.ArchNative,
    nat_common: compiler.NativeCommon,
    opt: Ocamlopt,
    rt: runtime.Artifacts,
    dynlink_dir: LazyPath,
) LazyPath {
    const runtime_dir = compiler.nativeRuntimeDir(b, rt);

    return opt.link(
        "ocamlnat",
        &.{ nat_common.cmxa, arch_nat.optcomp_cmxa, arch_nat.bytecomp_cmxa, dynlink_dir.path(b, "dynlink.cmxa"), arch_nat.toplevel_cmxa.?, arch_nat.compiled.impls.get("toplevel/topstart").?.impl.cmx },
        .{
            .includes = &.{ arch_byte.compiled.cmis_dir, arch_nat.compiled.dir, runtime_dir, dynlink_dir },
            .flags = driver.concat(b, compiler.native_link_flags, &.{"-linkall"}),
            .strip_debug = true,
        },
    );
}

pub const DebuggerByte = struct {
    cmi: LazyPath,
    parser_aux_cmi: LazyPath,
    cmis_dir: LazyPath,
    packed_cmo: LazyPath,
    entry_cmo: LazyPath,
};

pub fn compileDebugger(
    src: *const Source,
    ocamlc: Ocamlc,
    sources: Source.Resolver,
    cmis_dir: LazyPath,
    libs: otherlibs.Artifacts,
) DebuggerByte {
    const b = src.b;
    const m = src.manifest;

    const includes: []const LazyPath = &.{ cmis_dir, libs.unix_dir, libs.dynlink_dir };
    const dbg = ocamlc.compilePlan(m.debugger.plan, sources, .{
        .includes = includes,
        .flags = m.compiler.compflags,
    });
    const pack_wf = b.addWriteFiles();
    for (dbg.intfs.values()) |u| _ = pack_wf.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
    var pack_cmos: std.ArrayList(LazyPath) = .empty;
    for (m.debugger.packed_units) |key| {
        const name = std.fs.path.basename(key);
        const copied = pack_wf.addCopyFile(dbg.cmo(key).?, b.fmt("{s}.cmo", .{name}));
        pack_cmos.append(b.allocator, copied) catch @panic("OOM");
    }
    const packed_cmo = ocamlc.link("ocamldebug.cmo", pack_cmos.items, .{
        .includes = &.{pack_wf.getDirectory()},
        .flags = &.{"-pack"},
    });

    const entry_includes: []const LazyPath = &.{ cmis_dir, libs.unix_dir, libs.dynlink_dir, dbg.cmis_dir, packed_cmo.dirname() };
    const entry_intf = ocamlc.intf(src.path("debugger/ocamldebug_entry.mli"), "ocamldebug_entry", .{
        .includes = entry_includes,
        .flags = m.compiler.compflags,
    });
    const entry_impl = ocamlc.impl(src.path("debugger/ocamldebug_entry.ml"), "ocamldebug_entry", entry_intf.cmi, .{
        .includes = entry_includes,
        .flags = m.compiler.compflags,
    });

    return .{
        .cmi = packed_cmo.dirname().path(b, "ocamldebug.cmi"),
        .parser_aux_cmi = dbg.intfs.get("debugger/parser_aux").?.cmi,
        .cmis_dir = dbg.cmis_dir,
        .packed_cmo = packed_cmo,
        .entry_cmo = entry_impl.cmo,
    };
}

pub const DebuggerArtifacts = struct {
    exe: LazyPath,
    cmi: LazyPath,
    parser_aux_cmi: LazyPath,
};

pub fn linkDebugger(
    src: *const Source,
    base: DebuggerByte,
    ocamlc: Ocamlc,
    arch_byte: compiler.ArchByte,
    byte_common: compiler.ByteCommon,
    libs: otherlibs.Artifacts,
    host: Platform,
    host_launch_info_dir: LazyPath,
) DebuggerArtifacts {
    const b = src.b;
    const stublibs = b.addWriteFiles();
    if (libs.unix_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.unix_stubs.dllName(host));
    const dbg_flags: []const []const u8 = if (host.is_windows or libs.unix_stubs.shared_byt == null) &.{ "-linkall", "-no-check-prims" } else &.{"-linkall"};
    const includes: []const LazyPath = &.{
        host_launch_info_dir,
        arch_byte.compiled.cmis_dir,
        libs.unix_dir,
        libs.dynlink_dir,
        base.cmis_dir,
        base.packed_cmo.dirname(),
        stublibs.getDirectory(),
    };
    const exe = ocamlc.link("ocamldebug", &.{
        byte_common.ocamlcommon_cma,
        libs.unix_dir.path(b, "unix.cma"),
        libs.dynlink_dir.path(b, "dynlink.cma"),
        arch_byte.compiled.cmo("toplevel/genprintval").?,
        arch_byte.compiled.cmo("toplevel/topprinters").?,
        base.packed_cmo,
        base.entry_cmo,
    }, .{
        .includes = includes,
        .flags = driver.concat(b, compiler.launchFlags(b, host), dbg_flags),
    });
    return .{
        .exe = exe,
        .cmi = base.cmi,
        .parser_aux_cmi = base.parser_aux_cmi,
    };
}

pub const OcamldocByte = struct {
    sources: Source.Resolver,
    compiled: Ocamlc.Compiled,
    byte_lib_dir: LazyPath,
    odoc_info_cma: LazyPath,
    prog_cmos: []const LazyPath,
};

pub fn compileOcamldocByte(
    src: *const Source,
    ocamlc: Ocamlc,
    sources: Source.Resolver,
    cmis_dir: LazyPath,
    libs: otherlibs.Artifacts,
) OcamldocByte {
    const b = src.b;
    const m = src.manifest;

    const byte_includes: []const LazyPath = &.{ cmis_dir, libs.unix_dir, libs.str_dir, libs.dynlink_dir };
    const odoc_byte = ocamlc.compilePlan(m.ocamldoc.plan, sources, .{
        .includes = byte_includes,
        .flags = m.compiler.compflags,
    });
    const odoc_info_cma = ocamlc.archive("odoc_info.cma", odoc_byte.cmos(b, m.ocamldoc.odoc_info), .{});

    const lib_wf = b.addWriteFiles();
    _ = lib_wf.add("META", src.renderMeta("ocamldoc/META.in", &.{}));
    _ = lib_wf.addCopyFile(src.path("ocamldoc/ocamldoc.hva"), "ocamldoc.hva");
    _ = lib_wf.addCopyFile(odoc_info_cma, "odoc_info.cma");
    _ = lib_wf.addCopyFile(odoc_byte.cmo("ocamldoc/odoc_test").?, "odoc_test.cmo");
    for (odoc_byte.intfs.values()) |u| {
        if (std.mem.eql(u8, u.unit.name, "odoc_test")) continue;
        _ = lib_wf.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        if (u.unit.dest == .lib) {
            if (u.cmti) |cmti| _ = lib_wf.addCopyFile(cmti, b.fmt("{s}.cmti", .{u.unit.name}));
            _ = lib_wf.addCopyFile(u.src, b.fmt("{s}.mli", .{u.unit.name}));
        }
    }
    for (odoc_byte.impls.values()) |u| {
        if (u.unit.dest == .lib) {
            _ = lib_wf.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name}));
        }
    }

    return .{
        .sources = sources,
        .compiled = odoc_byte,
        .byte_lib_dir = lib_wf.getDirectory(),
        .odoc_info_cma = odoc_info_cma,
        .prog_cmos = odoc_byte.cmos(b, m.ocamldoc.ocamldoc),
    };
}

pub const OcamldocNative = struct {
    lib_dir: LazyPath,
    opt_exe: LazyPath,
};

pub fn compileOcamldocNative(
    src: *const Source,
    odoc_byte: OcamldocByte,
    opt: Ocamlopt,
    cmis_dir: LazyPath,
    arch_nat: compiler.ArchNative,
    nat_common: compiler.NativeCommon,
    libs: otherlibs.Artifacts,
    target_rt: runtime.Artifacts,
) OcamldocNative {
    const b = src.b;
    const m = src.manifest;
    const nat_includes: []const LazyPath = &.{ cmis_dir, arch_nat.compiled.dir, nat_common.cmxa.dirname(), libs.unix_dir, libs.str_dir, libs.dynlink_dir };
    const odoc_nat = opt.compilePlan(m.ocamldoc.plan, odoc_byte.sources, odoc_byte.compiled, .{
        .includes = nat_includes,
        .flags = m.compiler.compflags,
    });
    const odoc_info_nat = opt.archive("odoc_info", odoc_nat.cmxs(b, m.ocamldoc.odoc_info), .{});
    const lib_wf = b.addWriteFiles();
    _ = lib_wf.addCopyDirectory(odoc_byte.byte_lib_dir, "", .{});
    _ = lib_wf.addCopyFile(odoc_info_nat.cmxa, "odoc_info.cmxa");
    _ = lib_wf.addCopyFile(odoc_info_nat.lib, "odoc_info.a");
    for (odoc_nat.impls.values()) |u| {
        if (std.mem.eql(u8, u.unit.name, "odoc_test")) continue;
        _ = lib_wf.addCopyFile(u.impl.cmx, b.fmt("{s}.cmx", .{u.unit.name}));
    }

    const runtime_dir = b.addWriteFiles();
    _ = runtime_dir.addCopyDirectory(compiler.nativeRuntimeDir(b, target_rt), "", .{});
    _ = runtime_dir.addCopyFile(libs.unix_stubs.static_nat.getEmittedBin(), "libunixnat.a");
    _ = runtime_dir.addCopyFile(libs.str_stubs.static_nat.getEmittedBin(), "libcamlstrnat.a");

    var nat_objs: std.ArrayList(LazyPath) = .empty;
    nat_objs.appendSlice(b.allocator, &.{
        nat_common.cmxa,
        libs.unix_dir.path(b, "unix.cmxa"),
        libs.str_dir.path(b, "str.cmxa"),
        libs.dynlink_dir.path(b, "dynlink.cmxa"),
        odoc_info_nat.cmxa,
    }) catch @panic("OOM");
    nat_objs.appendSlice(b.allocator, odoc_nat.cmxs(b, m.ocamldoc.ocamldoc)) catch @panic("OOM");

    const opt_exe = opt.link("ocamldoc.opt", nat_objs.items, .{
        .includes = &.{ cmis_dir, arch_nat.compiled.dir, nat_common.cmxa.dirname(), runtime_dir.getDirectory(), libs.unix_dir, libs.str_dir, libs.dynlink_dir, odoc_nat.dir },
        .flags = compiler.native_link_flags,
        .strip_debug = true,
    });

    return .{
        .lib_dir = lib_wf.getDirectory(),
        .opt_exe = opt_exe,
    };
}

pub const OcamldocArtifacts = struct {
    byte: LazyPath,
    opt: ?LazyPath = null,
    lib_dir: LazyPath,
};

pub fn linkOcamldoc(
    src: *const Source,
    odoc_byte: OcamldocByte,
    odoc_nat: ?OcamldocNative,
    ocamlc: Ocamlc,
    ocamlcommon_cma: LazyPath,
    libs: otherlibs.Artifacts,
    target: Platform,
    host: Platform,
    host_launch_info_dir: LazyPath,
) OcamldocArtifacts {
    const b = src.b;
    var byte_objs: std.ArrayList(LazyPath) = .empty;
    byte_objs.appendSlice(b.allocator, &.{
        ocamlcommon_cma,
        libs.unix_dir.path(b, "unix.cma"),
        libs.str_dir.path(b, "str.cma"),
        libs.dynlink_dir.path(b, "dynlink.cma"),
        odoc_byte.odoc_info_cma,
    }) catch @panic("OOM");
    byte_objs.appendSlice(b.allocator, odoc_byte.prog_cmos) catch @panic("OOM");

    const stublibs = b.addWriteFiles();
    if (libs.unix_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.unix_stubs.dllName(target));
    if (libs.str_stubs.shared_byt) |dll| _ = stublibs.addCopyFile(dll.getEmittedBin(), libs.str_stubs.dllName(target));
    const odoc_flags = if (host.is_windows or libs.unix_stubs.shared_byt == null)
        driver.concat(b, compiler.launchFlags(b, host), &.{"-no-check-prims"})
    else
        compiler.launchFlags(b, host);
    const includes: []const LazyPath = &.{
        host_launch_info_dir,
        odoc_byte.compiled.cmis_dir,
        stublibs.getDirectory(),
    };
    const byte_exe = ocamlc.link("ocamldoc.byte", byte_objs.items, .{
        .includes = includes,
        .flags = odoc_flags,
    });

    return .{
        .byte = byte_exe,
        .opt = if (odoc_nat) |nat| nat.opt_exe else null,
        .lib_dir = if (odoc_nat) |nat| nat.lib_dir else odoc_byte.byte_lib_dir,
    };
}
