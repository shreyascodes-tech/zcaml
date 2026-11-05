//! FlexDLL: `flexlink`, the linker wrapper OCaml uses for executables and DLLs on
//! Windows, and the support objects it links into them. Upstream builds these from
//! the `flexdll` submodule (`make flexdll`); here `flexlink` drives `zig cc`
//! (see `build/flexdll/zig_toolchain.ml`).
const std = @import("std");
const Platform = @import("platform.zig");
const driver = @import("driver.zig");
const Tools = @import("tools.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const LazyPath = std.Build.LazyPath;

const module_names = [_][]const u8{ "version", "Compat", "coff", "cmdline", "create_dll", "reloc" };
const Modules = [module_names.len]LazyPath;

pub const Byte = struct {
    sources: Modules,
    cmis_dir: LazyPath,
    cmos: Modules,
};

/// `dep`: the `flexdll` package (`Source.Deps.flexdll`).
pub fn compileByte(boot: Ocamlc, dep: *std.Build.Dependency) Byte {
    const b = boot.b;
    const gen, _ = Tools.run(b, .gen_flexlink_sources, .{
        .flexdll_src_dir = .of(dep.path("")),
        .zig_toolchain_ml = .of(b.path("build/flexdll/zig_toolchain.ml")),
        .version_ml = .of("version.ml"),
        .compat_ml = .of("Compat.ml"),
        .coff_ml = .of("coff.ml"),
        .reloc_ml = .of("reloc.ml"),
    });
    const sources: Modules = .{
        gen.version_ml.lazyPath(),
        gen.compat_ml.lazyPath(),
        gen.coff_ml.lazyPath(),
        dep.path("cmdline.ml"),
        dep.path("create_dll.ml"),
        gen.reloc_ml.lazyPath(),
    };

    const cmis = b.addWriteFiles();
    var cmos: Modules = undefined;
    var includes: std.ArrayList(LazyPath) = .empty;
    for (sources, module_names, &cmos) |src, name, *cmo| {
        const r = boot.impl(src, name, null, .{ .includes = b.allocator.dupe(LazyPath, includes.items) catch @panic("OOM") });
        _ = cmis.addCopyFile(r.cmi, b.fmt("{s}.cmi", .{name}));
        includes.append(b.allocator, r.cmi.dirname()) catch @panic("OOM");
        cmo.* = r.cmo;
    }
    return .{ .sources = sources, .cmis_dir = cmis.getDirectory(), .cmos = cmos };
}

pub fn linkByte(boot: Ocamlc, byte: Byte, launch_info_dir: LazyPath, launch_flags: []const []const u8) LazyPath {
    return boot.link("flexlink.byte", &byte.cmos, .{
        .includes = &.{ byte.cmis_dir, launch_info_dir },
        .flags = launch_flags,
    });
}

/// `native_runtime_dir`: `libasmrun.a` & co. for the host (`runtime.Artifacts.native_runtime_dir`).
pub fn linkNative(opt: Ocamlopt, byte: Byte, native_runtime_dir: LazyPath) LazyPath {
    const b = opt.b;
    var cmxs: Modules = undefined;
    var includes: std.ArrayList(LazyPath) = .empty;
    includes.append(b.allocator, byte.cmis_dir) catch @panic("OOM");
    for (byte.sources, module_names, &cmxs) |src, name, *cmx| {
        const r = opt.impl(src, name, byte.cmis_dir.path(b, b.fmt("{s}.cmi", .{name})), .{
            .includes = b.allocator.dupe(LazyPath, includes.items) catch @panic("OOM"),
        });
        includes.append(b.allocator, r.cmx.dirname()) catch @panic("OOM");
        cmx.* = r.cmx;
    }
    includes.append(b.allocator, native_runtime_dir) catch @panic("OOM");
    return opt.link("flexlink.opt", &cmxs, .{ .includes = includes.items, .strip_debug = true });
}

/// Installed as `lib/ocaml/flexdll/`.
pub fn supportDir(b: *std.Build, dep: *std.Build.Dependency, p: Platform) LazyPath {
    const c = p.flexlinkChain();
    const wf = b.addWriteFiles();
    for ([_][]const u8{ "flexdll", "flexdll_initer" }) |name| {
        const obj = b.addObject(.{
            .name = b.fmt("{s}_{s}", .{ name, c }),
            .root_module = p.cModule(b, .{}),
        });
        obj.root_module.addIncludePath(dep.path(""));
        obj.root_module.addCSourceFile(.{
            .file = dep.path(b.fmt("{s}.c", .{name})),
            .flags = &.{ "-DMINGW", "-fno-sanitize=undefined", "-Wno-unused-parameter" },
        });
        _ = wf.addCopyFile(obj.getEmittedBin(), b.fmt("{s}_{s}.o", .{ name, c }));
    }
    _ = wf.addCopyFile(dep.path("flexdll.h"), "flexdll.h");
    return wf.getDirectory();
}
