const std = @import("std");
const TargetConfig = @import("target_config.zig").TargetConfig;
const SourceInfo = @import("source_info.zig").SourceInfo;
const DynlinkPackUnit = @import("manifests/manifest.zig").DynlinkPackUnit;
const RuntimeArtifacts = @import("runtime.zig").RuntimeArtifacts;
const StdlibArtifacts = @import("stdlib.zig").StdlibArtifacts;
const CompilerArtifacts = @import("compiler.zig").CompilerArtifacts;

pub const OtherlibsArtifacts = struct {
    dynlink_dir: std.Build.LazyPath,
    unix_dir: std.Build.LazyPath,
    str_dir: std.Build.LazyPath,
    threads_dir: std.Build.LazyPath,
    runtime_events_dir: std.Build.LazyPath,
    libunix_byt: *std.Build.Step.Compile,
    libunix_nat: *std.Build.Step.Compile,
    libstr_byt: *std.Build.Step.Compile,
    libstr_nat: *std.Build.Step.Compile,
    libthreads_byt: *std.Build.Step.Compile,
    libthreads_nat: *std.Build.Step.Compile,
    libruntime_events_byt: *std.Build.Step.Compile,
    libruntime_events_nat: *std.Build.Step.Compile,
    dllunix_byt: ?*std.Build.Step.Compile,
    dllstr_byt: ?*std.Build.Step.Compile,
    dllthreads_byt: ?*std.Build.Step.Compile,
    dllruntime_events_byt: ?*std.Build.Step.Compile,
    headers: []const HeaderToInstall,
};

pub const HeaderToInstall = struct {
    source: std.Build.LazyPath,
    dest_name: []const u8,
};

pub const BuildOtherlibsOptions = struct {
    src_info: SourceInfo,
    target_cfg: TargetConfig,
    target_rt: RuntimeArtifacts,
    target_stdlib: StdlibArtifacts,
    compiler: CompilerArtifacts,
    build_ocamlrun: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
};

pub fn buildOtherlibs(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
) !OtherlibsArtifacts {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const v = src_info.version;
    const cfg = options.target_cfg;

    const is_5_3_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 3, .patch = 0 }) != .lt;
    const is_5_1_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 1, .patch = 0 }) != .lt;

    // 1. Assemble C source lists from Manifest
    var unix_c_files: std.ArrayList([]const u8) = .empty;
    for (m.unix_common_c_sources) |f| try unix_c_files.append(b.allocator, b.fmt("otherlibs/unix/{s}", .{f}));
    const unix_os_c = if (cfg.is_windows) m.unix_win32_c_sources else m.unix_unix_c_sources;
    for (unix_os_c) |f| try unix_c_files.append(b.allocator, b.fmt("otherlibs/unix/{s}", .{f}));

    var str_c_files: std.ArrayList([]const u8) = .empty;
    for (m.str_c_sources) |f| try str_c_files.append(b.allocator, b.fmt("otherlibs/str/{s}", .{f}));

    var re_c_files: std.ArrayList([]const u8) = .empty;
    for (m.runtime_events_c_sources) |f| try re_c_files.append(b.allocator, b.fmt("otherlibs/runtime_events/{s}", .{f}));

    const threads_c_files = [_][]const u8{"otherlibs/systhreads/st_stubs.c"};

    // 2. Build static and shared C stub libraries using Zig's C compiler
    const unix_byt_name = if (is_5_1_or_newer) "unixbyt" else "unix";
    const str_byt_name = if (is_5_1_or_newer) "camlstrbyt" else "camlstr";
    const re_byt_name = if (is_5_1_or_newer) "camlruntime_eventsbyt" else "camlruntime_events";

    const unix_stubs = try buildStubLibraryPair(b, ocaml_dep, options, unix_byt_name, "unixnat", "otherlibs/unix", unix_c_files.items, &.{"-DCAML_BUILDING_UNIX"});
    const str_stubs = try buildStubLibraryPair(b, ocaml_dep, options, str_byt_name, "camlstrnat", "otherlibs/str", str_c_files.items, &.{});
    const threads_stubs = try buildStubLibraryPair(b, ocaml_dep, options, "threads", "threadsnat", "otherlibs/systhreads", &threads_c_files, &.{});
    const re_stubs = try buildStubLibraryPair(b, ocaml_dep, options, re_byt_name, "camlruntime_eventsnat", "otherlibs/runtime_events", re_c_files.items, &.{});

    // 3. Collect public C headers from otherlibs to install into <prefix>/lib/ocaml/caml/
    var headers: std.ArrayList(HeaderToInstall) = .empty;
    for (m.unix_headers) |h| {
        try headers.append(b.allocator, .{
            .source = ocaml_dep.path(b.fmt("otherlibs/unix/{s}", .{h})),
            .dest_name = std.fs.path.basename(h),
        });
    }
    for (m.runtime_events_headers) |h| {
        try headers.append(b.allocator, .{
            .source = ocaml_dep.path(b.fmt("otherlibs/runtime_events/{s}", .{h})),
            .dest_name = std.fs.path.basename(h),
        });
    }
    try headers.append(b.allocator, .{
        .source = ocaml_dep.path(m.threads_header),
        .dest_name = "threads.h",
    });

    // 4. Build str, runtime_events, unix, threads, and dynlink via native Zig `b.addRunArtifact` steps
    const str_dir = buildStrLib(b, ocaml_dep, options, is_5_1_or_newer);
    const re_dir = buildRuntimeEventsLib(b, ocaml_dep, options, is_5_1_or_newer);
    const unix_res = try buildUnixLib(b, ocaml_dep, options, is_5_1_or_newer);
    const threads_dir = buildThreadsLib(b, ocaml_dep, options, unix_res.cmi_dir);
    const dynlink_dir = try buildDynlinkLib(b, ocaml_dep, options, is_5_3_or_newer);

    return .{
        .dynlink_dir = dynlink_dir,
        .unix_dir = unix_res.install_dir,
        .str_dir = str_dir,
        .threads_dir = threads_dir,
        .runtime_events_dir = re_dir,
        .libunix_byt = unix_stubs.static_byt,
        .libunix_nat = unix_stubs.static_nat,
        .libstr_byt = str_stubs.static_byt,
        .libstr_nat = str_stubs.static_nat,
        .libthreads_byt = threads_stubs.static_byt,
        .libthreads_nat = threads_stubs.static_nat,
        .libruntime_events_byt = re_stubs.static_byt,
        .libruntime_events_nat = re_stubs.static_nat,
        .dllunix_byt = unix_stubs.shared_byt,
        .dllstr_byt = str_stubs.shared_byt,
        .dllthreads_byt = threads_stubs.shared_byt,
        .dllruntime_events_byt = re_stubs.shared_byt,
        .headers = headers.items,
    };
}

fn buildStrLib(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
    has_byt_suffix: bool,
) std.Build.LazyPath {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const wf = b.addWriteFiles();

    _ = wf.add("META", src_info.renderAtTemplate("otherlibs/str/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = src_info.version.version_string },
    }));

    const str_mli = ocaml_dep.path("otherlibs/str/str.mli");
    const str_ml = ocaml_dep.path("otherlibs/str/str.ml");

    const str_cmi = compileIntf(b, options, m.otherlibs_compflags, &.{}, str_mli, "str.cmi");
    const str_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{str_cmi.dirname()}, &.{}, str_cmi, str_ml, "str.cmo");

    const clib = if (has_byt_suffix) "-lcamlstrbyt" else "-lcamlstr";
    const str_cma = linkCma(b, options, &.{str_cmi.dirname()}, &.{ "-dllib", clib, "-cclib", clib }, &.{str_cmo}, "str.cma");

    _ = wf.addCopyFile(str_cma, "str.cma");
    _ = wf.addCopyFile(str_cmi, "str.cmi");
    _ = wf.addCopyFile(str_cmi.dirname().path(b, "str.cmti"), "str.cmti");
    _ = wf.addCopyFile(str_cmo.dirname().path(b, "str.cmt"), "str.cmt");
    _ = wf.addCopyFile(str_mli, "str.mli");
    return wf.getDirectory();
}

fn buildRuntimeEventsLib(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
    has_byt_suffix: bool,
) std.Build.LazyPath {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const wf = b.addWriteFiles();

    _ = wf.add("META", src_info.renderAtTemplate("otherlibs/runtime_events/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = src_info.version.version_string },
    }));

    const re_mli = ocaml_dep.path("otherlibs/runtime_events/runtime_events.mli");
    const re_ml = ocaml_dep.path("otherlibs/runtime_events/runtime_events.ml");

    const re_cmi = compileIntf(b, options, m.otherlibs_compflags, &.{}, re_mli, "runtime_events.cmi");
    const re_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{re_cmi.dirname()}, &.{}, re_cmi, re_ml, "runtime_events.cmo");

    const clib = if (has_byt_suffix) "-lcamlruntime_eventsbyt" else "-lcamlruntime_events";
    const re_cma = linkCma(b, options, &.{re_cmi.dirname()}, &.{ "-dllib", clib, "-cclib", clib }, &.{re_cmo}, "runtime_events.cma");

    _ = wf.addCopyFile(re_cma, "runtime_events.cma");
    _ = wf.addCopyFile(re_cmi, "runtime_events.cmi");
    _ = wf.addCopyFile(re_cmi.dirname().path(b, "runtime_events.cmti"), "runtime_events.cmti");
    _ = wf.addCopyFile(re_cmo.dirname().path(b, "runtime_events.cmt"), "runtime_events.cmt");
    _ = wf.addCopyFile(re_mli, "runtime_events.mli");
    return wf.getDirectory();
}

const UnixBuildResult = struct {
    install_dir: std.Build.LazyPath,
    cmi_dir: std.Build.LazyPath,
};

fn buildUnixLib(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
    has_byt_suffix: bool,
) !UnixBuildResult {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const cfg = options.target_cfg;
    const wf = b.addWriteFiles();

    _ = wf.add("META", src_info.renderAtTemplate("otherlibs/unix/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = src_info.version.version_string },
    }));

    const unix_mli = ocaml_dep.path("otherlibs/unix/unix.mli");
    const unix_ml = ocaml_dep.path(b.fmt("otherlibs/unix/unix_{s}.ml", .{cfg.unix_or_win32}));
    const unix_labels_mli_raw = ocaml_dep.path("otherlibs/unix/unixLabels.mli");
    const unix_labels_mli_exp = options.target_stdlib.unix_labels_mli;
    const unix_labels_ml = ocaml_dep.path("otherlibs/unix/unixLabels.ml");

    const unix_cmi = compileIntf(b, options, m.otherlibs_compflags, &.{"-nolabels"}, unix_mli, "unix.cmi");
    const unix_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{unix_cmi.dirname()}, &.{"-nolabels"}, unix_cmi, unix_ml, "unix.cmo");

    const labels_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &.{unix_cmi.dirname()}, &.{"-nolabels"}, unix_labels_mli_exp, "unixLabels.cmi");
    const labels_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ unix_cmi.dirname(), labels_cmi.dirname() }, &.{"-nolabels"}, labels_cmi, unix_labels_ml, "unixLabels.cmo");

    const clib = if (has_byt_suffix) "-lunixbyt" else "-lunix";
    var link_flags: std.ArrayList([]const u8) = .empty;
    try link_flags.appendSlice(b.allocator, &.{ "-dllib", clib, "-cclib", clib });
    if (cfg.is_windows) {
        try link_flags.appendSlice(b.allocator, &.{ "-cclib", "-lws2_32", "-cclib", "-ladvapi32" });
    }
    const unix_cma = linkCma(b, options, &.{ unix_cmi.dirname(), labels_cmi.dirname() }, link_flags.items, &.{ unix_cmo, labels_cmo }, "unix.cma");

    _ = wf.addCopyFile(unix_cma, "unix.cma");
    _ = wf.addCopyFile(unix_cmi, "unix.cmi");
    _ = wf.addCopyFile(unix_cmi.dirname().path(b, "unix.cmti"), "unix.cmti");
    _ = wf.addCopyFile(unix_cmo.dirname().path(b, "unix.cmt"), "unix.cmt");
    _ = wf.addCopyFile(unix_mli, "unix.mli");
    _ = wf.addCopyFile(labels_cmi, "unixLabels.cmi");
    _ = wf.addCopyFile(labels_cmi.dirname().path(b, "unixLabels.cmti"), "unixLabels.cmti");
    _ = wf.addCopyFile(labels_cmo.dirname().path(b, "unixLabels.cmt"), "unixLabels.cmt");
    _ = wf.addCopyFile(unix_labels_mli_raw, "unixLabels.mli");

    return .{
        .install_dir = wf.getDirectory(),
        .cmi_dir = unix_cmi.dirname(),
    };
}

fn buildThreadsLib(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
    unix_cmi_dir: std.Build.LazyPath,
) std.Build.LazyPath {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const wf = b.addWriteFiles();

    _ = wf.add("META", src_info.renderAtTemplate("otherlibs/systhreads/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = src_info.version.version_string },
    }));

    const thread_mli = ocaml_dep.path("otherlibs/systhreads/thread.mli");
    const thread_ml = ocaml_dep.path("otherlibs/systhreads/thread.ml");
    const event_mli = ocaml_dep.path("otherlibs/systhreads/event.mli");
    const event_ml = ocaml_dep.path("otherlibs/systhreads/event.ml");

    const thread_cmi = compileIntfWithDirs(b, options, m.systhreads_compflags, &.{unix_cmi_dir}, &.{}, thread_mli, "thread.cmi");
    const event_cmi = compileIntfWithDirs(b, options, m.systhreads_compflags, &.{unix_cmi_dir}, &.{}, event_mli, "event.cmi");

    const thread_cmo = compileImpl(b, options, m.systhreads_compflags, &.{ unix_cmi_dir, thread_cmi.dirname() }, &.{}, thread_cmi, thread_ml, "thread.cmo");
    const event_cmo = compileImpl(b, options, m.systhreads_compflags, &.{ unix_cmi_dir, thread_cmi.dirname(), event_cmi.dirname() }, &.{}, event_cmi, event_ml, "event.cmo");

    const threads_cma = linkCma(
        b,
        options,
        &.{ unix_cmi_dir, thread_cmi.dirname(), event_cmi.dirname() },
        &.{ "-dllib", "-lthreads", "-cclib", "-lthreads" },
        &.{ thread_cmo, event_cmo },
        "threads.cma",
    );

    _ = wf.addCopyFile(threads_cma, "threads.cma");
    _ = wf.addCopyFile(thread_cmi, "thread.cmi");
    _ = wf.addCopyFile(thread_cmi.dirname().path(b, "thread.cmti"), "thread.cmti");
    _ = wf.addCopyFile(thread_cmo.dirname().path(b, "thread.cmt"), "thread.cmt");
    _ = wf.addCopyFile(thread_mli, "thread.mli");
    _ = wf.addCopyFile(event_cmi, "event.cmi");
    _ = wf.addCopyFile(event_cmi.dirname().path(b, "event.cmti"), "event.cmti");
    _ = wf.addCopyFile(event_cmo.dirname().path(b, "event.cmt"), "event.cmt");
    _ = wf.addCopyFile(event_mli, "event.mli");

    return wf.getDirectory();
}

fn buildDynlinkLib(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
    has_modern_dynlink: bool,
) !std.Build.LazyPath {
    const src_info = options.src_info;
    const m = src_info.manifest;
    const v = src_info.version;
    const cfg = options.target_cfg;
    const wf = b.addWriteFiles();

    _ = wf.add("META", src_info.renderAtTemplate("otherlibs/dynlink/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = v.version_string },
        .{ .name = "natdynlink_archive", .value = if (cfg.runtimeAsmFile() != null) "dynlink.cmxa" else "" },
    }));

    const types_mli = ocaml_dep.path("otherlibs/dynlink/dynlink_types.mli");
    const types_ml = ocaml_dep.path("otherlibs/dynlink/dynlink_types.ml");
    const plat_ml = ocaml_dep.path("otherlibs/dynlink/dynlink_platform_intf.ml");
    const common_mli = ocaml_dep.path("otherlibs/dynlink/dynlink_common.mli");
    const common_ml = ocaml_dep.path("otherlibs/dynlink/dynlink_common.ml");
    const dynlink_mli = ocaml_dep.path("otherlibs/dynlink/dynlink.mli");
    const dynlink_byte_ml = ocaml_dep.path("otherlibs/dynlink/byte/dynlink.ml");

    if (has_modern_dynlink) {
        const so_ext = if (cfg.is_windows) "dll" else "so";
        const mn = m.magic_numbers.?;
        const dyn_cfg_content = src_info.renderAtTemplate("otherlibs/dynlink/dynlink_config.ml.in", &.{
            .{ .name = "configure_input", .value = "Generated by zcaml" },
            .{ .name = "MAGIC_LENGTH", .value = b.fmt("{d}", .{v.exec_magic_length.?}) },
            .{ .name = "QS", .value = "" },
            .{ .name = "SO", .value = so_ext },
            .{ .name = "CMO_MAGIC_NUMBER", .value = mn.cmo },
            .{ .name = "CMA_MAGIC_NUMBER", .value = mn.cma },
            .{ .name = "CMXS_MAGIC_NUMBER", .value = mn.cmxs },
            .{ .name = "bytecode_runtime_id", .value = cfg.bytecode_runtime_id, .version_specific = true },
            .{ .name = "target", .value = cfg.triplet, .version_specific = true },
        });
        const cfg_wf = b.addWriteFiles();
        const cfg_ml = cfg_wf.add("dynlink_config.ml", dyn_cfg_content);
        const cfg_mli = ocaml_dep.path("otherlibs/dynlink/dynlink_config.mli");

        const cmo_fmt_cmi = compileIntf(b, options, m.otherlibs_compflags, &.{ "-w", "-40" }, ocaml_dep.path("file_formats/cmo_format.mli"), "dynlink_cmo_format.cmi");
        const cmxs_fmt_cmi = compileIntf(b, options, m.otherlibs_compflags, &.{ "-w", "-40" }, ocaml_dep.path("file_formats/cmxs_format.mli"), "dynlink_cmxs_format.cmi");
        const cfg_cmi = compileIntf(b, options, m.otherlibs_compflags, &.{ "-w", "-40" }, cfg_mli, "dynlink_config.cmi");
        const cfg_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{cfg_cmi.dirname()}, &.{ "-w", "-40" }, cfg_cmi, cfg_ml, "dynlink_config.cmo");

        const base_dirs = [_]std.Build.LazyPath{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname() };
        const types_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &base_dirs, &.{ "-w", "-40" }, types_mli, "dynlink_types.cmi");
        const types_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname(), types_cmi.dirname() }, &.{ "-w", "-40" }, types_cmi, types_ml, "dynlink_types.cmo");

        const plat_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &.{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname(), types_cmi.dirname() }, &.{ "-w", "-40" }, plat_ml, "dynlink_platform_intf.cmi");
        const plat_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname(), types_cmi.dirname(), plat_cmi.dirname() }, &.{ "-w", "-40" }, plat_cmi, plat_ml, "dynlink_platform_intf.cmo");

        const common_dirs = [_]std.Build.LazyPath{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname(), types_cmi.dirname(), plat_cmi.dirname() };
        const common_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &common_dirs, &.{ "-w", "-40" }, common_mli, "dynlink_common.cmi");
        const common_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname(), types_cmi.dirname(), plat_cmi.dirname(), common_cmi.dirname() }, &.{ "-w", "-40" }, common_cmi, common_ml, "dynlink_common.cmo");

        const sym_mli = ocaml_dep.path("otherlibs/dynlink/byte/dynlink_symtable.mli");
        const sym_ml = ocaml_dep.path("otherlibs/dynlink/byte/dynlink_symtable.ml");
        const sym_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &common_dirs, &.{ "-w", "-40" }, sym_mli, "dynlink_symtable.cmi");
        const sym_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ cmo_fmt_cmi.dirname(), cmxs_fmt_cmi.dirname(), cfg_cmi.dirname(), types_cmi.dirname(), plat_cmi.dirname(), sym_cmi.dirname() }, &.{ "-w", "-40" }, sym_cmi, sym_ml, "dynlink_symtable.cmo");

        const dyn_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &common_dirs, &.{ "-w", "-40" }, dynlink_mli, "dynlink.cmi");
        const all_dyn_dirs = [_]std.Build.LazyPath{
            cmo_fmt_cmi.dirname(),
            cmxs_fmt_cmi.dirname(),
            cfg_cmi.dirname(),
            types_cmi.dirname(),
            plat_cmi.dirname(),
            common_cmi.dirname(),
            sym_cmi.dirname(),
            dyn_cmi.dirname(),
        };
        const dyn_cmo = compileImpl(b, options, m.otherlibs_compflags, &all_dyn_dirs, &.{ "-w", "-40" }, dyn_cmi, dynlink_byte_ml, "dynlink.cmo");

        const dyn_cma = linkCma(b, options, &all_dyn_dirs, &.{}, &.{
            cfg_cmo,
            types_cmo,
            plat_cmo,
            common_cmo,
            sym_cmo,
            dyn_cmo,
        }, "dynlink.cma");

        _ = wf.addCopyFile(dyn_cma, "dynlink.cma");
        _ = wf.addCopyFile(dyn_cmi, "dynlink.cmi");
        _ = wf.addCopyFile(dyn_cmi.dirname().path(b, "dynlink.cmti"), "dynlink.cmti");
        _ = wf.addCopyFile(dyn_cmo.dirname().path(b, "dynlink.cmt"), "dynlink.cmt");
        _ = wf.addCopyFile(dynlink_mli, "dynlink.mli");
        return wf.getDirectory();
    }

    // OCaml 5.0 - 5.2: compile and pack Dynlink_compilerlibs via `b.addRunArtifact`
    const pack_flags = [_][]const u8{ "-for-pack", "Dynlink_compilerlibs", "-w", "-40-66-70" };
    var unit_by_stem: std.StringHashMapUnmanaged(DynlinkPackUnit) = .empty;
    for (m.dynlink_pack_units) |du| {
        try unit_by_stem.put(b.allocator, du.stem, du);
    }

    const all_pack_cmis_wf = b.addWriteFiles();
    var pack_cmi_map: std.StringHashMapUnmanaged(std.Build.LazyPath) = .empty;
    var prev_wave_dirs: std.ArrayList(std.Build.LazyPath) = .empty;
    for (m.dynlink_pack_cmi_waves) |wave| {
        const wave_wf = b.addWriteFiles();
        for (wave) |stem| {
            const du = unit_by_stem.get(stem).?;
            const mli_lp = options.compiler.resolveSource(b, ocaml_dep, cfg.arch, du.mli_src);
            const cmi_name = b.fmt("{s}.cmi", .{stem});
            const cmi_lp = compileIntfWithDirs(b, options, m.otherlibs_compflags, prev_wave_dirs.items, &pack_flags, mli_lp, cmi_name);
            _ = wave_wf.addCopyFile(cmi_lp, cmi_name);
            _ = all_pack_cmis_wf.addCopyFile(cmi_lp, cmi_name);
            try pack_cmi_map.put(b.allocator, stem, cmi_lp);
        }
        try prev_wave_dirs.append(b.allocator, wave_wf.getDirectory());
    }

    const all_pack_cmis_dir = all_pack_cmis_wf.getDirectory();
    const pack_stage_wf = b.addWriteFiles();
    var pack_cmos: std.ArrayList(std.Build.LazyPath) = .empty;
    for (m.dynlink_pack_units) |du| {
        const ml_lp = options.compiler.resolveSource(b, ocaml_dep, cfg.arch, du.ml_src);
        const cmi_name = b.fmt("{s}.cmi", .{du.stem});
        const cmo_name = b.fmt("{s}.cmo", .{du.stem});
        const cmi_lp = pack_cmi_map.get(du.stem).?;
        const cmo_lp = compileImpl(b, options, m.otherlibs_compflags, &.{all_pack_cmis_dir}, &pack_flags, cmi_lp, ml_lp, cmo_name);
        _ = pack_stage_wf.addCopyFile(cmi_lp, cmi_name);
        const staged_cmo = pack_stage_wf.addCopyFile(cmo_lp, cmo_name);
        try pack_cmos.append(b.allocator, staged_cmo);
    }

    const packed_cmo = blk: {
        const run = b.addRunArtifact(options.build_ocamlrun);
        run.addFileArg(options.compiler.ocamlc_byte);
        run.addArgs(&.{ "-nostdlib", "-I" });
        run.addDirectoryArg(options.target_stdlib.stdlib_dir);
        run.addArgs(&.{ "-g", "-pack", "-o" });
        const out_lp = run.addOutputFileArg("dynlink_compilerlibs.cmo");
        for (pack_cmos.items) |cmo| run.addFileArg(cmo);
        break :blk out_lp;
    };

    const pack_dir = packed_cmo.dirname();
    const dyn_flags = [_][]const u8{ "-w", "-40-66-70" };

    const types_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &.{pack_dir}, &dyn_flags, types_mli, "dynlink_types.cmi");
    const types_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ pack_dir, types_cmi.dirname() }, &dyn_flags, types_cmi, types_ml, "dynlink_types.cmo");

    const plat_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &.{ pack_dir, types_cmi.dirname() }, &dyn_flags, plat_ml, "dynlink_platform_intf.cmi");
    const plat_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ pack_dir, types_cmi.dirname(), plat_cmi.dirname() }, &dyn_flags, plat_cmi, plat_ml, "dynlink_platform_intf.cmo");

    const common_dirs = [_]std.Build.LazyPath{ pack_dir, types_cmi.dirname(), plat_cmi.dirname() };
    const common_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &common_dirs, &dyn_flags, common_mli, "dynlink_common.cmi");
    const common_cmo = compileImpl(b, options, m.otherlibs_compflags, &.{ pack_dir, types_cmi.dirname(), plat_cmi.dirname(), common_cmi.dirname() }, &dyn_flags, common_cmi, common_ml, "dynlink_common.cmo");

    const dyn_cmi = compileIntfWithDirs(b, options, m.otherlibs_compflags, &common_dirs, &dyn_flags, dynlink_mli, "dynlink.cmi");
    const all_dyn_dirs = [_]std.Build.LazyPath{ pack_dir, types_cmi.dirname(), plat_cmi.dirname(), common_cmi.dirname(), dyn_cmi.dirname() };
    const dyn_cmo = compileImpl(b, options, m.otherlibs_compflags, &all_dyn_dirs, &dyn_flags, dyn_cmi, dynlink_byte_ml, "dynlink.cmo");

    const dyn_cma = linkCma(b, options, &all_dyn_dirs, &.{}, &.{
        packed_cmo,
        types_cmo,
        plat_cmo,
        common_cmo,
        dyn_cmo,
    }, "dynlink.cma");

    _ = wf.addCopyFile(dyn_cma, "dynlink.cma");
    _ = wf.addCopyFile(dyn_cmi, "dynlink.cmi");
    _ = wf.addCopyFile(dyn_cmi.dirname().path(b, "dynlink.cmti"), "dynlink.cmti");
    _ = wf.addCopyFile(dyn_cmo.dirname().path(b, "dynlink.cmt"), "dynlink.cmt");
    _ = wf.addCopyFile(dynlink_mli, "dynlink.mli");
    return wf.getDirectory();
}

fn compileIntf(
    b: *std.Build,
    options: BuildOtherlibsOptions,
    base_flags: []const []const u8,
    extra_flags: []const []const u8,
    src_mli: std.Build.LazyPath,
    out_cmi_name: []const u8,
) std.Build.LazyPath {
    return compileIntfWithDirs(b, options, base_flags, &.{}, extra_flags, src_mli, out_cmi_name);
}

fn compileIntfWithDirs(
    b: *std.Build,
    options: BuildOtherlibsOptions,
    base_flags: []const []const u8,
    inc_dirs: []const std.Build.LazyPath,
    extra_flags: []const []const u8,
    src_mli: std.Build.LazyPath,
    out_cmi_name: []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(options.build_ocamlrun);
    run.addFileArg(options.compiler.ocamlc_byte);
    run.addArgs(&.{ "-nostdlib", "-I" });
    run.addDirectoryArg(options.target_stdlib.stdlib_dir);
    for (inc_dirs) |d| {
        run.addArg("-I");
        run.addDirectoryArg(d);
    }
    run.addArgs(base_flags);
    run.addArgs(extra_flags);
    run.addArg("-o");
    const cmi_lp = run.addOutputFileArg(out_cmi_name);
    run.addArgs(&.{ "-c", "-intf" });
    run.addFileArg(src_mli);
    return cmi_lp;
}

fn compileImpl(
    b: *std.Build,
    options: BuildOtherlibsOptions,
    base_flags: []const []const u8,
    inc_dirs: []const std.Build.LazyPath,
    extra_flags: []const []const u8,
    cmi_lp: std.Build.LazyPath,
    src_ml: std.Build.LazyPath,
    out_cmo_name: []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(options.build_ocamlrun);
    run.addFileArg(options.compiler.ocamlc_byte);
    run.addArgs(&.{ "-nostdlib", "-I" });
    run.addDirectoryArg(options.target_stdlib.stdlib_dir);
    for (inc_dirs) |d| {
        run.addArg("-I");
        run.addDirectoryArg(d);
    }
    run.addArgs(base_flags);
    run.addArgs(extra_flags);
    run.addArg("-cmi-file");
    run.addFileArg(cmi_lp);
    run.addArg("-o");
    const cmo_lp = run.addOutputFileArg(out_cmo_name);
    run.addArgs(&.{ "-c", "-impl" });
    run.addFileArg(src_ml);
    return cmo_lp;
}

fn linkCma(
    b: *std.Build,
    options: BuildOtherlibsOptions,
    inc_dirs: []const std.Build.LazyPath,
    extra_flags: []const []const u8,
    cmos: []const std.Build.LazyPath,
    out_cma_name: []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(options.build_ocamlrun);
    run.addFileArg(options.compiler.ocamlc_byte);
    run.addArgs(&.{ "-nostdlib", "-I" });
    run.addDirectoryArg(options.target_stdlib.stdlib_dir);
    for (inc_dirs) |d| {
        run.addArg("-I");
        run.addDirectoryArg(d);
    }
    run.addArgs(&.{ "-g", "-a", "-linkall" });
    run.addArgs(extra_flags);
    run.addArg("-o");
    const cma_lp = run.addOutputFileArg(out_cma_name);
    for (cmos) |cmo| run.addFileArg(cmo);
    return cma_lp;
}

const StubLibraryPair = struct {
    static_byt: *std.Build.Step.Compile,
    static_nat: *std.Build.Step.Compile,
    shared_byt: ?*std.Build.Step.Compile,
};

fn buildStubLibraryPair(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildOtherlibsOptions,
    byt_name: []const u8,
    nat_name: []const u8,
    lib_subdir: []const u8,
    c_files: []const []const u8,
    extra_cflags: []const []const u8,
) !StubLibraryPair {
    const cfg = options.target_cfg;
    const headers_dir = options.target_rt.headers_dir;
    const headers_caml_dir = headers_dir.path(b, "caml");

    var byt_cflags: std.ArrayList([]const u8) = .empty;
    try byt_cflags.appendSlice(b.allocator, &.{
        "-O2",
        "-fno-strict-aliasing",
        "-fwrapv",
        "-fno-common",
        "-fno-sanitize=undefined",
        "-DCAMLDLLIMPORT=",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
    });
    if (cfg.is_windows) {
        try byt_cflags.appendSlice(b.allocator, &.{
            "-mms-bitfields",
            "-D__USE_MINGW_ANSI_STDIO=0",
            "-DUNICODE",
            "-D_UNICODE",
            "-DWINDOWS_UNICODE=1",
        });
    } else {
        try byt_cflags.append(b.allocator, "-D_FILE_OFFSET_BITS=64");
    }
    try byt_cflags.appendSlice(b.allocator, extra_cflags);

    var nat_cflags: std.ArrayList([]const u8) = .empty;
    try nat_cflags.appendSlice(b.allocator, byt_cflags.items);
    try nat_cflags.appendSlice(b.allocator, &.{
        "-DNATIVE_CODE",
        b.fmt("-DTARGET_{s}", .{cfg.arch}),
        b.fmt("-DMODEL_{s}", .{cfg.model}),
        b.fmt("-DSYS_{s}", .{cfg.system}),
    });

    const addStubIncludes = struct {
        fn call(
            builder: *std.Build,
            mod: *std.Build.Module,
            dep: *std.Build.Dependency,
            h_dir: std.Build.LazyPath,
            h_caml_dir: std.Build.LazyPath,
            sub: []const u8,
        ) void {
            mod.addIncludePath(h_dir);
            mod.addIncludePath(h_caml_dir);
            mod.addIncludePath(dep.path("runtime"));
            mod.addIncludePath(dep.path("otherlibs/unix"));
            mod.addIncludePath(dep.path("otherlibs/unix/caml"));
            mod.addIncludePath(dep.path(sub));
            mod.addIncludePath(dep.path(builder.fmt("{s}/caml", .{sub})));
        }
    }.call;

    const static_byt = b.addLibrary(.{
        .linkage = .static,
        .name = byt_name,
        .root_module = b.createModule(.{
            .target = cfg.resolved,
            .optimize = options.optimize,
            .pic = true,
            .link_libc = true,
        }),
    });
    addStubIncludes(b, static_byt.root_module, ocaml_dep, headers_dir, headers_caml_dir, lib_subdir);
    static_byt.root_module.addCSourceFiles(.{
        .root = ocaml_dep.path(""),
        .files = c_files,
        .flags = byt_cflags.items,
    });

    const static_nat = b.addLibrary(.{
        .linkage = .static,
        .name = nat_name,
        .root_module = b.createModule(.{
            .target = cfg.resolved,
            .optimize = options.optimize,
            .pic = true,
            .link_libc = true,
        }),
    });
    addStubIncludes(b, static_nat.root_module, ocaml_dep, headers_dir, headers_caml_dir, lib_subdir);
    static_nat.root_module.addCSourceFiles(.{
        .root = ocaml_dep.path(""),
        .files = c_files,
        .flags = nat_cflags.items,
    });

    const shared_byt: ?*std.Build.Step.Compile = if (!cfg.is_windows) blk: {
        const dll = b.addLibrary(.{
            .linkage = .dynamic,
            .name = byt_name,
            .root_module = b.createModule(.{
                .target = cfg.resolved,
                .optimize = options.optimize,
                .pic = true,
                .link_libc = true,
            }),
        });
        dll.linker_allow_shlib_undefined = true;
        addStubIncludes(b, dll.root_module, ocaml_dep, headers_dir, headers_caml_dir, lib_subdir);
        dll.root_module.addCSourceFiles(.{
            .root = ocaml_dep.path(""),
            .files = c_files,
            .flags = byt_cflags.items,
        });
        if (std.mem.eql(u8, lib_subdir, "otherlibs/unix")) {
            dll.root_module.linkSystemLibrary("m", .{});
        }
        if (std.mem.eql(u8, lib_subdir, "otherlibs/systhreads")) {
            dll.root_module.linkSystemLibrary("pthread", .{});
        }
        break :blk dll;
    } else null;

    return .{
        .static_byt = static_byt,
        .static_nat = static_nat,
        .shared_byt = shared_byt,
    };
}
