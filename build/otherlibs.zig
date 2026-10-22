const std = @import("std");
const TargetConfig = @import("target_config.zig").TargetConfig;
const SourceInfo = @import("source_info.zig").SourceInfo;
const RuntimeArtifacts = @import("runtime.zig").RuntimeArtifacts;
const StdlibArtifacts = @import("stdlib.zig").StdlibArtifacts;
const CompilerArtifacts = @import("compiler.zig").CompilerArtifacts;
const Tools = @import("tools/root.zig");

pub const OtherlibsArtifacts = struct {
    otherlibs_dir: std.Build.LazyPath,
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
    const v = src_info.version;
    const cfg = options.target_cfg;

    const is_5_3_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 3, .patch = 0 }) != .lt;
    const is_5_2_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 2, .patch = 0 }) != .lt;
    const is_5_1_or_newer = v.sem_ver.order(.{ .major = 5, .minor = 1, .patch = 0 }) != .lt;

    // 1. Parse C source lists from otherlibs Makefiles
    const unix_common_c = src_info.parseMakefileListFromFile("otherlibs/unix/Makefile", "COMMON_C_SOURCES", &.{});
    const unix_os_c = src_info.parseMakefileListFromFile("otherlibs/unix/Makefile", "OS_C_SOURCES", &.{
        .{ .name = "UNIX_OR_WIN32", .values = &.{cfg.unix_or_win32} },
    });
    var unix_c_files: std.ArrayList([]const u8) = .empty;
    for (unix_common_c) |f| try unix_c_files.append(b.allocator, b.fmt("otherlibs/unix/{s}", .{f}));
    for (unix_os_c) |f| try unix_c_files.append(b.allocator, b.fmt("otherlibs/unix/{s}", .{f}));

    const str_c = if (is_5_1_or_newer)
        src_info.parseMakefileListFromFile("otherlibs/str/Makefile", "C_SOURCES", &.{})
    else
        src_info.parseMakefileListFromFile("otherlibs/str/Makefile", "COBJS", &.{
            .{ .name = "O", .values = &.{"c"} },
        });
    var str_c_files: std.ArrayList([]const u8) = .empty;
    for (str_c) |f| try str_c_files.append(b.allocator, b.fmt("otherlibs/str/{s}", .{f}));

    const re_c = if (is_5_1_or_newer)
        src_info.parseMakefileListFromFile("otherlibs/runtime_events/Makefile", "C_SOURCES", &.{})
    else
        src_info.parseMakefileListFromFile("otherlibs/runtime_events/Makefile", "COBJS", &.{
            .{ .name = "O", .values = &.{"c"} },
        });
    var re_c_files: std.ArrayList([]const u8) = .empty;
    for (re_c) |f| try re_c_files.append(b.allocator, b.fmt("otherlibs/runtime_events/{s}", .{f}));

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
    const unix_headers = src_info.parseMakefileListFromFile("otherlibs/unix/Makefile", "HEADERS", &.{});
    const re_headers = src_info.parseMakefileListFromFile("otherlibs/runtime_events/Makefile", "HEADERS", &.{});
    const threads_header_rel = if (is_5_2_or_newer) "otherlibs/systhreads/caml/threads.h" else "otherlibs/systhreads/threads.h";

    var headers: std.ArrayList(HeaderToInstall) = .empty;
    for (unix_headers) |h| {
        try headers.append(b.allocator, .{
            .source = ocaml_dep.path(b.fmt("otherlibs/unix/{s}", .{h})),
            .dest_name = std.fs.path.basename(h),
        });
    }
    for (re_headers) |h| {
        try headers.append(b.allocator, .{
            .source = ocaml_dep.path(b.fmt("otherlibs/runtime_events/{s}", .{h})),
            .dest_name = std.fs.path.basename(h),
        });
    }
    try headers.append(b.allocator, .{
        .source = ocaml_dep.path(threads_header_rel),
        .dest_name = "threads.h",
    });

    // 4. Render META files and dynlink_config.ml from upstream .in templates
    const wf = b.addWriteFiles();
    const dynlink_meta_lp = wf.add("dynlink_META", src_info.renderAtTemplate("otherlibs/dynlink/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = v.version_string },
        .{ .name = "natdynlink_archive", .value = if (cfg.runtimeAsmFile() != null) "dynlink.cmxa" else "" },
    }));
    const unix_meta_lp = wf.add("unix_META", src_info.renderAtTemplate("otherlibs/unix/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = v.version_string },
    }));
    const str_meta_lp = wf.add("str_META", src_info.renderAtTemplate("otherlibs/str/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = v.version_string },
    }));
    const threads_meta_lp = wf.add("threads_META", src_info.renderAtTemplate("otherlibs/systhreads/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = v.version_string },
    }));
    const re_meta_lp = wf.add("runtime_events_META", src_info.renderAtTemplate("otherlibs/runtime_events/META.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "VERSION", .value = v.version_string },
    }));

    const dynlink_config_lp: ?Tools.InputFile = if (is_5_3_or_newer) blk: {
        const so_ext = if (cfg.is_windows) "dll" else "so";
        const content = src_info.renderAtTemplate("otherlibs/dynlink/dynlink_config.ml.in", &.{
            .{ .name = "configure_input", .value = "Generated by zcaml" },
            .{ .name = "MAGIC_LENGTH", .value = b.fmt("{d}", .{v.exec_magic_length.?}) },
            .{ .name = "QS", .value = "" },
            .{ .name = "SO", .value = so_ext },
            .{ .name = "CMO_MAGIC_NUMBER", .value = src_info.magicNumber("CMO") },
            .{ .name = "CMA_MAGIC_NUMBER", .value = src_info.magicNumber("CMA") },
            .{ .name = "CMXS_MAGIC_NUMBER", .value = src_info.magicNumber("CMXS") },
            .{ .name = "bytecode_runtime_id", .value = cfg.bytecode_runtime_id, .version_specific = true },
            .{ .name = "target", .value = cfg.triplet, .version_specific = true },
        });
        break :blk .of(wf.add("dynlink_config.ml", content));
    } else null;

    const dynlink_pack_intfs = if (!is_5_3_or_newer)
        src_info.parseMakefileListFromFile("otherlibs/dynlink/Makefile", "COMPILERLIBS_INTFS", &.{})
    else
        &.{};
    const dynlink_pack_sources = if (!is_5_3_or_newer)
        src_info.parseMakefileListFromFile("otherlibs/dynlink/Makefile", "COMPILERLIBS_SOURCES", &.{})
    else
        &.{};

    // 5. Parse COMPFLAGS from otherlibs Makefiles
    const otherlibs_compflags = src_info.parseMakefileListFromFile("otherlibs/Makefile.otherlibs.common", "COMPFLAGS", &.{
        .{ .name = "EXTRACAMLFLAGS", .values = &.{} },
    });
    const systhreads_compflags = src_info.parseMakefileListFromFile("otherlibs/systhreads/Makefile", "COMPFLAGS", &.{});

    // 6. Run build_otherlibs tool command using build_ocamlrun + newly built ocamlc.byte
    var cmd = Tools.Command{
        .build_otherlibs = .{
            .ocamlrun = .of(options.build_ocamlrun.getEmittedBin()),
            .compiler_dir = .of(options.compiler.compiler_dir),
            .stdlib_dir = .of(options.target_stdlib.stdlib_dir),
            .ocaml_src_dir = .of(ocaml_dep.path("")),
            .unix_or_win32 = cfg.unix_or_win32,
            .is_windows_target = cfg.is_windows,
            .has_byt_suffix = is_5_1_or_newer,
            .has_modern_dynlink = is_5_3_or_newer,
            .dynlink_config_ml = dynlink_config_lp,
            .dynlink_meta = .of(dynlink_meta_lp),
            .unix_meta = .of(unix_meta_lp),
            .str_meta = .of(str_meta_lp),
            .threads_meta = .of(threads_meta_lp),
            .runtime_events_meta = .of(re_meta_lp),
            .otherlibs_compflags = otherlibs_compflags,
            .systhreads_compflags = systhreads_compflags,
            .dynlink_pack_intfs = dynlink_pack_intfs,
            .dynlink_pack_sources = dynlink_pack_sources,
            .out_dir = .of("otherlibs"),
        },
    };
    _ = cmd.run(b);

    return .{
        .otherlibs_dir = cmd.build_otherlibs.out_dir.lazyPath(),
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
