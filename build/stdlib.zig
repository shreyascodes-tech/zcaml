//! The bytecode stdlib bootstrap, followed by target-native artifacts.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const driver = @import("driver.zig");
const Ocamlc = driver.Ocamlc;
const Ocamlopt = driver.Ocamlopt;
const runtime = @import("runtime.zig");
const configure = @import("configure.zig");
const Tools = @import("tools.zig");
const LazyPath = std.Build.LazyPath;

pub const Common = struct {
    /// Bytecode stdlib files without `runtime-launch-info` (target-independent).
    base_dir: LazyPath,
    /// `runtime-launch-info` directory for the build host, used by build-time tools.
    build_launch_info_dir: LazyPath,
    meta: LazyPath,
    expanded_dir: LazyPath,
    sources: Source.Resolver,
    compiled: Ocamlc.Compiled,
};

pub fn buildCommon(src: *const Source, primitives: LazyPath, build_rt: runtime.Artifacts) Common {
    const b = src.b;
    const m = src.manifest;

    const config = b.addWriteFiles();
    const sys_ml = config.add("sys.ml", configure.stdlibSysMl(src.*));
    const meta = config.add("META", src.renderMeta("stdlib/META.in", &.{}));

    const gen, _ = Tools.run(b, .gen_stdlib_sources, .{
        .ocaml_src_dir = .of(src.path("")),
        .expanded_dir = .of("stdlib_expanded"),
    });
    const expanded_dir = gen.expanded_dir.lazyPath();

    var sources: Source.Resolver = .{ .source = src, .arch = null, .expanded_dir = expanded_dir };
    sources.gen.put(.stdlib_sys_ml, sys_ml);

    const boot: Ocamlc = .{
        .b = b,
        .ocamlrun = build_rt.ocamlrun_step.?,
        .exe = src.path("boot/ocamlc"),
        .stdlib_dir = null,
        .primitives = primitives,
        .prefix_map = src.prefixMap(),
        .cwd = src.path("stdlib"),
        .strip_dir = "stdlib",
    };
    const compiled = boot.compilePlan(m.stdlib.plan, sources, .{ .flags = m.stdlib.compflags });

    const out = b.addWriteFiles();
    for (compiled.intfs.values()) |u| {
        _ = out.addCopyFile(u.cmi, b.fmt("{s}.cmi", .{u.unit.name}));
        if (u.cmti) |cmti| {
            _ = out.addCopyFile(cmti, b.fmt("{s}.cmti", .{u.unit.name}));
            installSource(out, sources, u.unit.src);
        }
    }
    for (compiled.impls.values()) |u| {
        _ = out.addCopyFile(u.impl.cmt, b.fmt("{s}.cmt", .{u.unit.name}));
        installSource(out, sources, u.unit.src);
    }
    _ = out.addCopyFile(compiled.cmo("std_exit").?, "std_exit.cmo");
    _ = out.addCopyFile(boot.archive("stdlib.cma", compiled.cmos(b, m.stdlib.cma), .{}), "stdlib.cma");

    const build_launch_info_dir = buildLaunchInfoDir(src.*, build_rt);

    return .{
        .base_dir = out.getDirectory(),
        .build_launch_info_dir = build_launch_info_dir,
        .meta = meta,
        .expanded_dir = expanded_dir,
        .sources = sources,
        .compiled = compiled,
    };
}

pub fn buildLaunchInfoDir(src: Source, rt: runtime.Artifacts) LazyPath {
    const b = src.b;
    const header_exe = buildHeaderExe(src, rt);
    const gen, _ = Tools.run(b, .gen_launch_info, .{
        .header_exe = .of(header_exe.getEmittedBin()),
        .runtime_launch_info = .of("runtime-launch-info"),
    });
    const launch_wf = b.addWriteFiles();
    _ = launch_wf.addCopyFile(gen.runtime_launch_info.lazyPath(), "runtime-launch-info");
    return launch_wf.getDirectory();
}

pub const Artifacts = struct {
    /// Contents of `lib/ocaml/` contributed by the stdlib (flat, as upstream installs it).
    dir: LazyPath,
    /// Directory containing only `runtime-launch-info` for this platform.
    launch_info_dir: LazyPath,
    meta: LazyPath,
    /// Module-alias-expanded sources (`Manifest.Src.expanded`), also used by otherlibs.
    expanded_dir: LazyPath,
    sources: Source.Resolver,
    /// Bootstrap interfaces and sources reused by the native compiler.
    compiled: Ocamlc.Compiled,
};

pub fn buildForTarget(src: *const Source, common: Common, target_arch: ?Platform.Arch, launch_info_dir: LazyPath, nat_dir: ?LazyPath) Artifacts {
    const b = src.b;
    const out = b.addWriteFiles();
    _ = out.addCopyDirectory(common.base_dir, "", .{});
    _ = out.addCopyFile(launch_info_dir.path(b, "runtime-launch-info"), "runtime-launch-info");
    if (nat_dir) |nd| _ = out.addCopyDirectory(nd, "", .{});

    var sources = common.sources;
    sources.arch = target_arch;
    return .{
        .dir = out.getDirectory(),
        .launch_info_dir = launch_info_dir,
        .meta = common.meta,
        .expanded_dir = common.expanded_dir,
        .sources = sources,
        .compiled = common.compiled,
    };
}

/// Compile target-native `.cmx`, `std_exit.o`, `stdlib.cmxa`, and `stdlib.a` (depends only on `(arch, system)`).
pub fn buildNativeDir(src: *const Source, common: Common, compiler: Ocamlopt, p: Platform) LazyPath {
    const b = src.b;
    var opt = compiler;
    opt.stdlib_dir = null;
    opt.cwd = src.path("stdlib");
    opt.strip_dir = "stdlib";
    var sources = common.sources;
    sources.arch = p.arch;
    const compiled = opt.compilePlan(src.manifest.stdlib.plan, sources, common.compiled, .{
        .flags = driver.concat(b, src.manifest.stdlib.compflags, if (p.is_elf) &.{"-function-sections"} else &.{}),
    });
    const out = b.addWriteFiles();
    for (compiled.impls.values()) |u| {
        _ = out.addCopyFile(u.impl.cmx, b.fmt("{s}.cmx", .{u.unit.name}));
    }
    _ = out.addCopyFile(compiled.impls.get("std_exit").?.impl.obj, "std_exit.o");
    const archive = opt.archive("stdlib", compiled.cmxs(b, src.manifest.stdlib.cma), .{});
    _ = out.addCopyFile(archive.cmxa, "stdlib.cmxa");
    _ = out.addCopyFile(archive.lib, "stdlib.a");
    return out.getDirectory();
}

/// Install the pristine source of a unit next to its artifacts (`stdlib/foo.ml` -> `foo.ml`).
fn installSource(out: *std.Build.Step.WriteFile, sources: Source.Resolver, src: Source.Manifest.Src) void {
    const name = switch (src) {
        .upstream, .expanded => |rel| std.fs.path.basename(rel),
        .gen => |g| switch (g) {
            .stdlib_sys_ml => "sys.ml",
            else => std.debug.panic("unexpected generated stdlib source '{t}'", .{g}),
        },
        .arch => unreachable,
    };
    _ = out.addCopyFile(sources.original(src), name);
}

/// The executable embedded into bytecode programs that launches `ocamlrun`.
fn buildHeaderExe(src: Source, target_rt: runtime.Artifacts) *std.Build.Step.Compile {
    const b = src.b;
    const p = target_rt.platform;

    const exe = b.addExecutable(.{
        .name = "tmpheader",
        .root_module = runtime.cModule(b, p, .{ .optimize = .ReleaseSmall, .strip = true }),
    });
    target_rt.addIncludes(src, exe.root_module);

    var extra: []const []const u8 = &.{};
    if (p.is_windows) {
        extra = &.{"-DwmainCRTStartup=wmain"};
        exe.mingw_unicode_entry_point = true;
        exe.subsystem = .console;
    }
    exe.root_module.addCSourceFile(.{
        .file = src.path("stdlib/header.c"),
        .flags = p.c.flags(b, extra),
    });
    return exe;
}
