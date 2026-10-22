const std = @import("std");
const TargetConfig = @import("target_config.zig").TargetConfig;
const SourceInfo = @import("source_info.zig").SourceInfo;
const Tools = @import("tools/root.zig");

pub const RuntimeArtifacts = struct {
    target_cfg: TargetConfig,
    headers_dir: std.Build.LazyPath,
    primitives: std.Build.LazyPath,
    prims_c: std.Build.LazyPath,
    ocamlyacc: *std.Build.Step.Compile,
    libcamlrun: *std.Build.Step.Compile,
    ocamlrun: *std.Build.Step.Compile,
    libasmrun: ?*std.Build.Step.Compile,
    libcomprmarsh: ?*std.Build.Step.Compile,
    zstd: ?*std.Build.Step.Compile,
};

pub const BuildRuntimeOptions = struct {
    src_info: SourceInfo,
    target_cfg: TargetConfig,
    optimize: std.builtin.OptimizeMode,
    stdlib_dir: []const u8 = "../lib/ocaml",
};

pub fn buildRuntime(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildRuntimeOptions,
) !RuntimeArtifacts {
    const src_info = options.src_info;
    const cfg = options.target_cfg;
    const target = cfg.resolved;

    const m = src_info.manifest;
    const os_c_sources = if (cfg.is_windows) m.runtime_win32_c_sources else m.runtime_unix_c_sources;
    const bytecode_only_c_sources = m.runtime_bytecode_only_c_sources;
    const native_only_c_sources = m.runtime_native_only_c_sources;

    const has_zstd = blk: {
        for (bytecode_only_c_sources) |name| {
            if (std.mem.eql(u8, name, "zstd")) break :blk true;
        }
        break :blk false;
    };
    const zstd_lib: ?*std.Build.Step.Compile = if (has_zstd) blk: {
        const zstd_dep = b.dependency("zstd", .{
            .target = target,
            .optimize = options.optimize,
            .pie = true,
        });
        break :blk zstd_dep.artifact("zstd");
    } else null;

    var bytecode_c_rel_paths: std.ArrayList([]const u8) = .empty;
    var bytecode_c_inputs: std.ArrayList(Tools.InputFile) = .empty;

    for (m.runtime_common_c_sources) |name| {
        const rel = b.fmt("runtime/{s}.c", .{name});
        try bytecode_c_rel_paths.append(b.allocator, rel);
        try bytecode_c_inputs.append(b.allocator, .of(ocaml_dep.path(rel)));
    }
    for (os_c_sources) |name| {
        const rel = b.fmt("runtime/{s}.c", .{name});
        try bytecode_c_rel_paths.append(b.allocator, rel);
        try bytecode_c_inputs.append(b.allocator, .of(ocaml_dep.path(rel)));
    }
    for (bytecode_only_c_sources) |name| {
        const rel = b.fmt("runtime/{s}.c", .{name});
        try bytecode_c_rel_paths.append(b.allocator, rel);
        try bytecode_c_inputs.append(b.allocator, .of(ocaml_dep.path(rel)));
    }

    // 2. Run gen_runtime tool to generate opnames.h, jumptbl.h, primitives, prims.c
    const is_5_2_or_newer = src_info.version.sem_ver.order(.{ .major = 5, .minor = 2, .patch = 0 }) != .lt;
    const is_5_5_or_newer = src_info.version.sem_ver.order(.{ .major = 5, .minor = 5, .patch = 0 }) != .lt;
    var gen_cmd = Tools.Command{
        .gen_runtime = .{
            .instruct_h = .of(ocaml_dep.path("runtime/caml/instruct.h")),
            .opnames_h = .of("opnames.h"),
            .jumptbl_h = .of("jumptbl.h"),
            .primitives = .of("primitives"),
            .prims_c = .of("prims.c"),
            .has_gen_primsc = is_5_2_or_newer,
            .has_byte_program_mode = is_5_5_or_newer,
            .c_files = bytecode_c_inputs.items,
        },
    };
    _ = gen_cmd.run(b);

    // 3. Assemble generated header directory from strict .h.in templates
    const headers_wf = b.addWriteFiles();
    _ = headers_wf.add("caml/m.h", cfg.generateMH(b, src_info));
    _ = headers_wf.add("caml/s.h", cfg.generateSH(b, src_info));
    _ = headers_wf.add("caml/version.h", TargetConfig.generateVersionH(b, src_info));
    if (TargetConfig.generateExecH(b, src_info)) |exec_h| {
        _ = headers_wf.add("caml/exec.h", exec_h);
    }
    _ = headers_wf.add("build_config.h", cfg.generateBuildConfigH(b, options.stdlib_dir));
    _ = headers_wf.addCopyFile(gen_cmd.gen_runtime.opnames_h.lazyPath(), "caml/opnames.h");
    _ = headers_wf.addCopyFile(gen_cmd.gen_runtime.jumptbl_h.lazyPath(), "caml/jumptbl.h");

    const headers_dir = headers_wf.getDirectory();
    const headers_caml_dir = headers_dir.path(b, "caml");

    // Common C compiler flags for OCaml runtime
    var base_cflags: std.ArrayList([]const u8) = .empty;
    try base_cflags.appendSlice(b.allocator, &.{
        "-O2",
        "-fno-strict-aliasing",
        "-fwrapv",
        "-fno-common",
        "-fno-sanitize=undefined",
        "-DIN_CAML_RUNTIME",
        "-DCAMLDLLIMPORT=",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
    });
    if (cfg.is_windows) {
        try base_cflags.appendSlice(b.allocator, &.{
            "-mms-bitfields",
            "-D__USE_MINGW_ANSI_STDIO=0",
            "-DUNICODE",
            "-D_UNICODE",
            "-DWINDOWS_UNICODE=1",
        });
    } else {
        try base_cflags.append(b.allocator, "-D_FILE_OFFSET_BITS=64");
        if (cfg.is_elf) {
            try base_cflags.append(b.allocator, "-ffunction-sections");
        }
    }

    // 4. Build ocamlyacc
    var yacc_c_files: std.ArrayList([]const u8) = .empty;
    if (cfg.is_windows) {
        try yacc_c_files.append(b.allocator, "yacc/wstr.c");
    }
    try yacc_c_files.appendSlice(b.allocator, m.ocamlyacc_c_sources);

    const ocamlyacc = b.addExecutable(.{
        .name = "ocamlyacc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = options.optimize,
            .link_libc = true,
        }),
    });
    var yacc_cflags: std.ArrayList([]const u8) = .empty;
    try yacc_cflags.appendSlice(b.allocator, &.{
        "-O2",
        "-fno-strict-aliasing",
        "-fwrapv",
        "-fno-sanitize=undefined",
        "-DNDEBUG",
        "-DCAMLDLLIMPORT=",
    });
    if (cfg.is_windows) {
        try yacc_cflags.appendSlice(b.allocator, &.{
            "-DUNICODE",
            "-D_UNICODE",
            "-DWINDOWS_UNICODE=1",
        });
    }
    ocamlyacc.root_module.addIncludePath(headers_dir);
    ocamlyacc.root_module.addIncludePath(headers_caml_dir);
    ocamlyacc.root_module.addIncludePath(ocaml_dep.path("runtime"));
    ocamlyacc.root_module.addCSourceFiles(.{
        .root = ocaml_dep.path(""),
        .files = yacc_c_files.items,
        .flags = yacc_cflags.items,
    });
    if (cfg.is_windows) {
        ocamlyacc.mingw_unicode_entry_point = true;
    }

    // 5. Build libcamlrun.a
    const libcamlrun = b.addLibrary(.{
        .linkage = .static,
        .name = "camlrun",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = options.optimize,
            .link_libc = true,
        }),
    });
    libcamlrun.root_module.addIncludePath(headers_dir);
    libcamlrun.root_module.addIncludePath(headers_caml_dir);
    libcamlrun.root_module.addIncludePath(ocaml_dep.path("runtime"));
    if (zstd_lib) |z| libcamlrun.root_module.linkLibrary(z);
    libcamlrun.root_module.addCSourceFiles(.{
        .root = ocaml_dep.path(""),
        .files = bytecode_c_rel_paths.items,
        .flags = base_cflags.items,
    });

    // 6. Build ocamlrun executable
    const ocamlrun = b.addExecutable(.{
        .name = "ocamlrun",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = options.optimize,
            .link_libc = true,
        }),
    });
    ocamlrun.root_module.addIncludePath(headers_dir);
    ocamlrun.root_module.addIncludePath(headers_caml_dir);
    ocamlrun.root_module.addIncludePath(ocaml_dep.path("runtime"));
    ocamlrun.root_module.addCSourceFile(.{
        .file = gen_cmd.gen_runtime.prims_c.lazyPath(),
        .flags = base_cflags.items,
    });
    ocamlrun.root_module.linkLibrary(libcamlrun);
    if (zstd_lib) |z| ocamlrun.root_module.linkLibrary(z);
    linkRuntimeSystemLibs(ocamlrun.root_module, cfg);
    if (cfg.is_elf) {
        ocamlrun.rdynamic = true;
    }
    if (cfg.is_windows) {
        ocamlrun.mingw_unicode_entry_point = true;
    }

    // 7. Build libasmrun.a (when target has a native code backend)
    const libasmrun: ?*std.Build.Step.Compile = if (cfg.runtimeAsmFile()) |asm_file| blk: {
        var native_c_rel_paths: std.ArrayList([]const u8) = .empty;
        for (m.runtime_common_c_sources) |name| {
            try native_c_rel_paths.append(b.allocator, b.fmt("runtime/{s}.c", .{name}));
        }
        for (os_c_sources) |name| {
            try native_c_rel_paths.append(b.allocator, b.fmt("runtime/{s}.c", .{name}));
        }
        for (native_only_c_sources) |name| {
            try native_c_rel_paths.append(b.allocator, b.fmt("runtime/{s}.c", .{name}));
        }
        if (std.mem.endsWith(u8, asm_file, ".S")) {
            try native_c_rel_paths.append(b.allocator, b.fmt("runtime/{s}", .{asm_file}));
        }

        var native_cflags: std.ArrayList([]const u8) = .empty;
        try native_cflags.appendSlice(b.allocator, base_cflags.items);
        try native_cflags.appendSlice(b.allocator, &.{
            "-DNATIVE_CODE",
            b.fmt("-DTARGET_{s}", .{cfg.arch}),
            b.fmt("-DMODEL_{s}", .{cfg.model}),
            b.fmt("-DSYS_{s}", .{cfg.system}),
        });

        const asmrun = b.addLibrary(.{
            .linkage = .static,
            .name = "asmrun",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = options.optimize,
                .link_libc = true,
            }),
        });
        asmrun.root_module.addIncludePath(headers_dir);
        asmrun.root_module.addIncludePath(headers_caml_dir);
        asmrun.root_module.addIncludePath(ocaml_dep.path("runtime"));
        asmrun.root_module.addCSourceFiles(.{
            .root = ocaml_dep.path(""),
            .files = native_c_rel_paths.items,
            .flags = native_cflags.items,
        });
        break :blk asmrun;
    } else null;

    // 8. Build libcomprmarsh.a (OCaml 5.2+)
    const libcomprmarsh: ?*std.Build.Step.Compile = if (zstd_lib) |z| blk: {
        const cm = b.addLibrary(.{
            .linkage = .static,
            .name = "comprmarsh",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = options.optimize,
                .pic = true,
                .link_libc = true,
            }),
        });
        cm.root_module.addIncludePath(headers_dir);
        cm.root_module.addIncludePath(headers_caml_dir);
        cm.root_module.addIncludePath(ocaml_dep.path("runtime"));
        cm.root_module.linkLibrary(z);
        cm.root_module.addCSourceFile(.{
            .file = ocaml_dep.path("runtime/zstd.c"),
            .flags = base_cflags.items,
        });
        break :blk cm;
    } else null;

    return .{
        .target_cfg = cfg,
        .headers_dir = headers_dir,
        .primitives = gen_cmd.gen_runtime.primitives.lazyPath(),
        .prims_c = gen_cmd.gen_runtime.prims_c.lazyPath(),
        .ocamlyacc = ocamlyacc,
        .libcamlrun = libcamlrun,
        .ocamlrun = ocamlrun,
        .libasmrun = libasmrun,
        .libcomprmarsh = libcomprmarsh,
        .zstd = zstd_lib,
    };
}

fn linkRuntimeSystemLibs(mod: *std.Build.Module, cfg: TargetConfig) void {
    if (cfg.is_windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("uuid", .{});
        mod.linkSystemLibrary("version", .{});
        mod.linkSystemLibrary("shlwapi", .{});
        mod.linkSystemLibrary("api-ms-win-core-synch-l1-2-0", .{});
    } else {
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("pthread", .{});
        if (cfg.is_linux) {
            mod.linkSystemLibrary("dl", .{});
        }
    }
}
