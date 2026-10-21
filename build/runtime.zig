const std = @import("std");
const TargetConfig = @import("target_config.zig").TargetConfig;
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
    libcomprmarsh: *std.Build.Step.Compile,
    zstd: *std.Build.Step.Compile,
};

pub const BuildRuntimeOptions = struct {
    target_cfg: TargetConfig,
    optimize: std.builtin.OptimizeMode,
    stdlib_dir: []const u8 = "../lib/ocaml",
};

pub fn buildRuntime(
    b: *std.Build,
    ocaml_dep: *std.Build.Dependency,
    options: BuildRuntimeOptions,
) !RuntimeArtifacts {
    const cfg = options.target_cfg;
    const target = cfg.resolved;

    const zstd_dep = b.dependency("zstd", .{
        .target = target,
        .optimize = options.optimize,
        .pie = true,
    });
    const zstd_lib = zstd_dep.artifact("zstd");

    // 1. Collect bytecode C files for primitive extraction and compilation
    var bytecode_c_rel_paths: std.ArrayList([]const u8) = .empty;
    var bytecode_c_inputs: std.ArrayList(Tools.InputFile) = .empty;

    for (common_c_sources) |name| {
        const rel = b.fmt("runtime/{s}.c", .{name});
        try bytecode_c_rel_paths.append(b.allocator, rel);
        try bytecode_c_inputs.append(b.allocator, .of(ocaml_dep.path(rel)));
    }
    {
        const os_rel = b.fmt("runtime/{s}.c", .{cfg.unix_or_win32});
        try bytecode_c_rel_paths.append(b.allocator, os_rel);
        try bytecode_c_inputs.append(b.allocator, .of(ocaml_dep.path(os_rel)));
    }
    for (bytecode_only_c_sources) |name| {
        const rel = b.fmt("runtime/{s}.c", .{name});
        try bytecode_c_rel_paths.append(b.allocator, rel);
        try bytecode_c_inputs.append(b.allocator, .of(ocaml_dep.path(rel)));
    }

    // 2. Run gen_runtime tool to generate opnames.h, jumptbl.h, primitives, prims.c
    var gen_cmd = Tools.Command{
        .gen_runtime = .{
            .instruct_h = .of(ocaml_dep.path("runtime/caml/instruct.h")),
            .opnames_h = .of("opnames.h"),
            .jumptbl_h = .of("jumptbl.h"),
            .primitives = .of("primitives"),
            .prims_c = .of("prims.c"),
            .c_files = bytecode_c_inputs.items,
        },
    };
    _ = gen_cmd.run(b);

    // 3. Assemble generated header directory with m.h, s.h, version.h, exec.h, opnames.h, jumptbl.h, build_config.h
    const headers_wf = b.addWriteFiles();
    _ = headers_wf.add("caml/m.h", cfg.generateMH(b));
    _ = headers_wf.add("caml/s.h", cfg.generateSH(b));
    _ = headers_wf.add("caml/version.h", TargetConfig.generateVersionH());
    _ = headers_wf.add("caml/exec.h", TargetConfig.generateExecH());
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
        .root = ocaml_dep.path("yacc"),
        .files = if (cfg.is_windows) yacc_c_sources_win32 else yacc_c_sources_unix,
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
    libcamlrun.root_module.linkLibrary(zstd_lib);
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
    ocamlrun.root_module.linkLibrary(zstd_lib);
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
        for (common_c_sources) |name| {
            try native_c_rel_paths.append(b.allocator, b.fmt("runtime/{s}.c", .{name}));
        }
        try native_c_rel_paths.append(b.allocator, b.fmt("runtime/{s}.c", .{cfg.unix_or_win32}));
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

    // 8. Build libcomprmarsh.a
    const libcomprmarsh = b.addLibrary(.{
        .linkage = .static,
        .name = "comprmarsh",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = options.optimize,
            .pic = true,
            .link_libc = true,
        }),
    });
    libcomprmarsh.root_module.addIncludePath(headers_dir);
    libcomprmarsh.root_module.addIncludePath(headers_caml_dir);
    libcomprmarsh.root_module.addIncludePath(ocaml_dep.path("runtime"));
    libcomprmarsh.root_module.linkLibrary(zstd_lib);
    libcomprmarsh.root_module.addCSourceFile(.{
        .file = ocaml_dep.path("runtime/zstd.c"),
        .flags = base_cflags.items,
    });

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

pub const common_c_sources: []const []const u8 = &.{
    "addrmap",
    "afl",
    "alloc",
    "array",
    "backtrace",
    "bigarray",
    "blake2",
    "callback",
    "codefrag",
    "compare",
    "custom",
    "debugger",
    "domain",
    "dynlink",
    "extern",
    "fail",
    "fiber",
    "finalise",
    "floats",
    "gc_ctrl",
    "gc_stats",
    "globroots",
    "hash",
    "intern",
    "ints",
    "io",
    "lexing",
    "lf_skiplist",
    "main",
    "major_gc",
    "md5",
    "memory",
    "memprof",
    "meta",
    "minor_gc",
    "misc",
    "obj",
    "parsing",
    "platform",
    "printexc",
    "prng",
    "roots",
    "runtime_events",
    "shared_heap",
    "signals",
    "skiplist",
    "startup_aux",
    "str",
    "sync",
    "sys",
    "weak",
};

pub const bytecode_only_c_sources: []const []const u8 = &.{
    "backtrace_byt",
    "fail_byt",
    "fix_code",
    "interp",
    "startup_byt",
    "zstd",
};

pub const native_only_c_sources: []const []const u8 = &.{
    "backtrace_nat",
    "clambda_checks",
    "dynlink_nat",
    "fail_nat",
    "frame_descriptors",
    "startup_nat",
    "signals_nat",
};

pub const yacc_c_sources_unix: []const []const u8 = &.{
    "closure.c",
    "error.c",
    "lalr.c",
    "lr0.c",
    "main.c",
    "mkpar.c",
    "output.c",
    "reader.c",
    "skeleton.c",
    "symtab.c",
    "verbose.c",
    "warshall.c",
};

pub const yacc_c_sources_win32: []const []const u8 = &.{
    "wstr.c",
    "closure.c",
    "error.c",
    "lalr.c",
    "lr0.c",
    "main.c",
    "mkpar.c",
    "output.c",
    "reader.c",
    "skeleton.c",
    "symtab.c",
    "verbose.c",
    "warshall.c",
};
