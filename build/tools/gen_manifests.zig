const std = @import("std");
const Manifest = @import("../manifests/manifest.zig");
const utils = @import("utils.zig");
const InputDir = utils.InputDir;
const OutputFile = utils.OutputFile;

const Self = @This();

ocaml_src_dir: InputDir,
out_file: OutputFile,

const core_include_dirs = [_][]const u8{
    "utils",
    "parsing",
    "typing",
    "bytecomp",
    "file_formats",
    "lambda",
    "middle_end",
    "middle_end/closure",
    "middle_end/flambda",
    "middle_end/flambda/base_types",
    "asmcomp",
    "driver",
    "toplevel",
    "tools",
};

pub fn run(self: *Self, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const src_root = self.ocaml_src_dir.path();
    var root_dir = try std.Io.Dir.cwd().openDir(io, src_root, .{});
    defer root_dir.close(io);

    // 1. Parse VERSION and build-aux/ocaml_version.m4
    const version_m4 = try root_dir.readFileAlloc(io, "build-aux/ocaml_version.m4", arena, .unlimited);
    const version_file = try root_dir.readFileAlloc(io, "VERSION", arena, .unlimited);
    const ver = try parseOcamlVersion(arena, version_m4, version_file);

    const is_5_5_or_newer = ver.major > 5 or (ver.major == 5 and ver.minor >= 5);
    const is_5_2_or_newer = ver.major > 5 or (ver.major == 5 and ver.minor >= 2);
    const is_5_1_or_newer = ver.major > 5 or (ver.major == 5 and ver.minor >= 1);

    // 2. Query root Makefile via `make -s -n clean`
    const root_vars = try queryMakeVars(io, gpa, arena, src_root, "Makefile", &.{
        "ARCH=amd64",
        "NATIVE_COMPILER=true",
        "arch_specific_SOURCES=$(intel_SOURCES)",
        "UNIX_OR_WIN32=",
        "BYTECODE_C_SOURCES=",
        "NATIVE_C_SOURCES=",
        "TSAN_NATIVE_RUNTIME_C_SOURCES=",
        "O=o",
        "A=a",
        "S=s",
        "SO=so",
        "EXE=",
    }, &.{
        "runtime_COMMON_C_SOURCES",
        "runtime_UNIX_C_SOURCES",
        "runtime_WIN32_C_SOURCES",
        "runtime_BYTECODE_ONLY_C_SOURCES",
        "runtime_NATIVE_ONLY_C_SOURCES",
        "comprmarsh_C_SOURCES",
        "ocamlyacc_OTHER_MODULES",
        "STDLIB_MODULE_BASENAMES",
        "PERVASIVES",
        "ARCH_SPECIFIC",
        "COMPFLAGS",
        // 5.2+
        "ocamlcommon_CMO_FILES",
        "ocamlbytecomp_CMO_FILES",
        "ocamlmiddleend_CMO_FILES",
        "ocamloptcomp_CMO_FILES",
        "ocamltoplevel_CMO_FILES",
        "ocamllex_CMO_FILES",
        "ocamlprof_CMO_FILES",
        "ocamlcp_CMO_FILES",
        "ocamloptp_CMO_FILES",
        "ocamlmklib_CMO_FILES",
        "ocamlmktop_CMO_FILES",
        // 5.0 - 5.1
        "COMMON",
        "COMMON_CMI",
        "BYTECOMP",
        "MIDDLE_END",
        "MIDDLE_END_CMI",
        "OPTCOMP",
        "OPTCOMP_CMI",
        "TOPLEVEL",
        "ocamllex_MODULES",
        "ocamlprof_MODULES",
        "ocamlcp_MODULES",
        "ocamloptp_MODULES",
        "ocamlmklib_MODULES",
        "ocamlmktop_MODULES",
    });

    // 3. Query stdlib and otherlibs Makefiles
    const stdlib_vars = try queryMakeVars(io, gpa, arena, src_root, "stdlib/Makefile", &.{
        "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{"COMPFLAGS"});

    const unix_unix_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/unix/Makefile", &.{
        "UNIX_OR_WIN32=unix", "EXTRACAMLFLAGS=", "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "COMMON_C_SOURCES", "OS_C_SOURCES", "HEADERS", "COMPFLAGS" });

    const unix_win32_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/unix/Makefile", &.{
        "UNIX_OR_WIN32=win32", "EXTRACAMLFLAGS=", "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{"OS_C_SOURCES"});

    const str_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/str/Makefile", &.{
        "EXTRACAMLFLAGS=", "O=c", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "C_SOURCES", "COBJS", "COMPFLAGS" });

    const re_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/runtime_events/Makefile", &.{
        "EXTRACAMLFLAGS=", "O=c", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "C_SOURCES", "COBJS", "HEADERS" });

    const threads_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/systhreads/Makefile", &.{
        "EXTRACAMLFLAGS=", "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{"COMPFLAGS"});

    // 4. Parse compiler_compflags
    const compiler_compflags = if (is_5_1_or_newer) blk: {
        const bc_src = try root_dir.readFileAlloc(io, "Makefile.build_config.in", arena, .unlimited);
        break :blk try parseSimpleMakefileVar(arena, bc_src, "OC_COMMON_COMPFLAGS");
    } else blk: {
        // Filter out -I flags from 5.0 COMPFLAGS
        const raw = root_vars.get("COMPFLAGS").?;
        var filtered: std.ArrayList([]const u8) = .empty;
        var skip_next = false;
        for (raw) |tok| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            if (std.mem.eql(u8, tok, "-I")) {
                skip_next = true;
                continue;
            }
            try filtered.append(arena, tok);
        }
        break :blk filtered.items;
    };

    // 5. Runtime C sources
    const rt_common = root_vars.get("runtime_COMMON_C_SOURCES").?;
    const rt_unix = if (root_vars.get("runtime_UNIX_C_SOURCES")) |s| (if (s.len > 0) s else &[_][]const u8{"unix"}) else &[_][]const u8{"unix"};
    const rt_win32 = if (root_vars.get("runtime_WIN32_C_SOURCES")) |s| (if (s.len > 0) s else &[_][]const u8{"win32"}) else &[_][]const u8{"win32"};
    const rt_byt = root_vars.get("runtime_BYTECODE_ONLY_C_SOURCES").?;
    const rt_nat = root_vars.get("runtime_NATIVE_ONLY_C_SOURCES").?;
    const comprmarsh = if (root_vars.get("comprmarsh_C_SOURCES")) |s| s else &[_][]const u8{};

    const yacc_raw = root_vars.get("ocamlyacc_OTHER_MODULES").?;
    var ocamlyacc_c_sources: std.ArrayList([]const u8) = .empty;
    for (yacc_raw) |item| {
        if (std.mem.endsWith(u8, item, ".c")) {
            try ocamlyacc_c_sources.append(arena, item);
        } else {
            try ocamlyacc_c_sources.append(arena, try std.fmt.allocPrint(arena, "{s}.c", .{item}));
        }
    }

    // 6. Stdlib plan from STDLIB_MODULE_BASENAMES, stdlib/Compflags and stdlib/.depend
    const stdlib_plan = try computeStdlibPlan(io, arena, root_dir, root_vars.get("STDLIB_MODULE_BASENAMES").?);

    var pervasives: std.ArrayList([]const u8) = .empty;
    try pervasives.appendSlice(arena, stdlib_plan.cma);
    for (root_vars.get("PERVASIVES").?) |p| {
        if (!containsStr(pervasives.items, p)) try pervasives.append(arena, p);
    }

    // 7. Compiler & Tools module lists and waves
    const arch_specific = root_vars.get("ARCH_SPECIFIC").?;
    const comp_lists = try extractCompilerLists(
        io,
        gpa,
        arena,
        src_root,
        root_dir,
        &root_vars,
        is_5_2_or_newer,
        is_5_1_or_newer,
    );

    const compiler_plan = try computeCompilerPlan(
        io,
        arena,
        root_dir,
        arch_specific,
        &comp_lists,
    );

    const lex_plan = try computeLexPlan(
        io,
        arena,
        root_dir,
        comp_lists.ocamllex_cmos,
    );

    // 8. Otherlibs C sources & Dynlink 5.0-5.2 pack plan
    const str_c = if (str_vars.get("C_SOURCES")) |s| (if (s.len > 0) s else str_vars.get("COBJS").?) else str_vars.get("COBJS").?;
    const re_c = if (re_vars.get("C_SOURCES")) |s| (if (s.len > 0) s else re_vars.get("COBJS").?) else re_vars.get("COBJS").?;

    const dynlink_standalone = fileExists(io, root_dir, "otherlibs/dynlink/dynlink_config.ml.in");
    const dynlink_pack: Manifest.Plan = if (!dynlink_standalone)
        try computeDynlinkPackPlan(io, gpa, arena, src_root, root_dir)
    else
        .{ .cmi_waves = &.{}, .cmo_units = &.{} };

    // 9. Features
    const features: Manifest.Features = .{
        .relocatable = is_5_5_or_newer,
        .header_format = if (is_5_5_or_newer)
            .launch_info_5_5
        else if (is_5_2_or_newer)
            .launch_info_5_2
        else
            .camlheader,
        .gen_primsc = fileExists(io, root_dir, "runtime/gen_primsc.sh"),
        .byte_program_mode = is_5_5_or_newer,
        .config_common_template = fileExists(io, root_dir, "utils/config.common.ml.in"),
        .config_generated_template = fileExists(io, root_dir, "utils/config.generated.ml.in"),
        .byterntm = fileExists(io, root_dir, "bytecomp/byterntm.mll"),
        .yacc_strict = is_5_1_or_newer,
        .byt_stub_suffix = is_5_1_or_newer,
        .dynlink_standalone = dynlink_standalone,
        .zstd = containsStr(rt_byt, "zstd"),
    };

    // 10. Serialize Manifest as ZON
    const manifest: Manifest = .{
        .version = ver,
        .features = features,
        .runtime = .{
            .common_c_sources = rt_common,
            .unix_c_sources = rt_unix,
            .win32_c_sources = rt_win32,
            .bytecode_only_c_sources = rt_byt,
            .native_only_c_sources = rt_nat,
            .comprmarsh_c_sources = comprmarsh,
            .ocamlyacc_c_sources = ocamlyacc_c_sources.items,
        },
        .stdlib = .{
            .compflags = stdlib_vars.get("COMPFLAGS").?,
            .plan = stdlib_plan.plan,
            .cma = stdlib_plan.cma,
            .pervasives = pervasives.items,
        },
        .compiler = .{
            .compflags = compiler_compflags,
            .plan = compiler_plan,
            .ocamlcommon = comp_lists.ocamlcommon_cmos,
            .ocamlbytecomp = comp_lists.ocamlbytecomp_cmos,
            .ocamlmiddleend = comp_lists.ocamlmiddleend_cmos,
            .ocamloptcomp = comp_lists.ocamloptcomp_cmos,
            .ocamltoplevel = comp_lists.ocamltoplevel_cmos,
            .ocamlprof = comp_lists.ocamlprof_cmos,
            .ocamlcp = comp_lists.ocamlcp_cmos,
            .ocamloptp = comp_lists.ocamloptp_cmos,
            .ocamlmklib = comp_lists.ocamlmklib_cmos,
            .ocamlmktop = comp_lists.ocamlmktop_cmos,
        },
        .lex = .{
            .plan = lex_plan,
            .ocamllex = comp_lists.ocamllex_cmos,
        },
        .otherlibs = .{
            .compflags = str_vars.get("COMPFLAGS").?,
            .systhreads_compflags = threads_vars.get("COMPFLAGS").?,
            .unix_common_c_sources = unix_unix_vars.get("COMMON_C_SOURCES").?,
            .unix_unix_c_sources = unix_unix_vars.get("OS_C_SOURCES").?,
            .unix_win32_c_sources = unix_win32_vars.get("OS_C_SOURCES").?,
            .unix_headers = unix_unix_vars.get("HEADERS").?,
            .str_c_sources = str_c,
            .runtime_events_c_sources = re_c,
            .runtime_events_headers = re_vars.get("HEADERS").?,
            .threads_header = if (fileExists(io, root_dir, "otherlibs/systhreads/caml/threads.h"))
                "otherlibs/systhreads/caml/threads.h"
            else
                "otherlibs/systhreads/threads.h",
            .dynlink_pack = dynlink_pack,
        },
    };

    var write_buf: [8192]u8 = undefined;
    var fw = try self.out_file.writer(io, &write_buf);
    defer fw.file.close(io);
    const w = &fw.interface;

    @setEvalBranchQuota(10_000);
    try std.zon.stringify.serialize(manifest, .{ .whitespace = true }, w);
    try w.writeByte('\n');
    try fw.flush();
}

const Unit = Manifest.Unit;
const WaveUnit = Manifest.WaveUnit;
const Src = Manifest.Src;

/// x86-only backend modules (`asmcomp/x86_*`)
const intel_archs: []const Manifest.Arch = &.{ .amd64, .i386 };

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn queryMakeVars(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root: []const u8,
    makefile_rel: []const u8,
    make_overrides: []const []const u8,
    var_names: []const []const u8,
) !std.StringHashMapUnmanaged([]const []const u8) {
    const dir_rel = std.fs.path.dirname(makefile_rel) orelse "";
    const work_dir = if (dir_rel.len > 0)
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_root, dir_rel })
    else
        src_root;
    const mf_base = std.fs.path.basename(makefile_rel);

    var stdin_buf: std.ArrayList(u8) = .empty;
    for (var_names) |vname| {
        try stdin_buf.appendSlice(arena, try std.fmt.allocPrint(arena, "$(info ZCAML:{s}=$({s}))\n", .{ vname, vname }));
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "make", "-C", work_dir, "-s", "-n", "clean" });
    try argv.appendSlice(arena, make_overrides);
    try argv.appendSlice(arena, &.{ "-f", mf_base, "-f", "-" });

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    if (child.stdin) |stdin_file| {
        try stdin_file.writeStreamingAll(io, stdin_buf.items);
        stdin_file.close(io);
        child.stdin = null;
    }

    var stdout_reader = child.stdout.?.reader(io, &.{});
    const stdout_data = try stdout_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(stdout_data);

    var stderr_reader = child.stderr.?.reader(io, &.{});
    const stderr_data = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(stderr_data);

    _ = try child.wait(io);

    var map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var lines = std.mem.splitScalar(u8, stdout_data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "ZCAML:")) continue;
        const rest = line["ZCAML:".len..];
        const eq_idx = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const k = try arena.dupe(u8, rest[0..eq_idx]);
        const val_str = rest[eq_idx + 1 ..];

        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, val_str, " \t");
        while (it.next()) |tok| {
            try list.append(arena, try arena.dupe(u8, tok));
        }
        try map.put(arena, k, list.items);
    }

    return map;
}

const CompilerLists = struct {
    ocamlcommon_cmos: []const []const u8,
    ocamlcommon_cmis: []const []const u8,
    ocamlbytecomp_cmos: []const []const u8,
    ocamlmiddleend_cmos: []const []const u8,
    ocamlmiddleend_cmis: []const []const u8,
    ocamloptcomp_cmos: []const []const u8,
    ocamloptcomp_cmis: []const []const u8,
    ocamltoplevel_cmos: []const []const u8,
    ocamllex_cmos: []const []const u8,
    ocamlprof_cmos: []const []const u8,
    ocamlcp_cmos: []const []const u8,
    ocamloptp_cmos: []const []const u8,
    ocamlmklib_cmos: []const []const u8,
    ocamlmktop_cmos: []const []const u8,
};

fn extractCompilerLists(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root: []const u8,
    root_dir: std.Io.Dir,
    root_vars: *const std.StringHashMapUnmanaged([]const []const u8),
    is_5_2_or_newer: bool,
    is_5_1_or_newer: bool,
) !CompilerLists {
    if (is_5_2_or_newer) {
        // Also get *_BYTE_CMI_FILES from make
        const cmi_vars = try queryMakeVars(io, gpa, arena, src_root, "Makefile", &.{
            "ARCH=amd64",
            "NATIVE_COMPILER=true",
            "arch_specific_SOURCES=$(intel_SOURCES)",
            "O=o",
            "A=a",
            "S=s",
            "SO=so",
            "EXE=",
        }, &.{
            "ocamlcommon_BYTE_CMI_FILES",
            "ocamlmiddleend_BYTE_CMI_FILES",
            "ocamloptcomp_BYTE_CMI_FILES",
        });

        return .{
            .ocamlcommon_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlcommon_CMO_FILES").?),
            .ocamlcommon_cmis = try normalizeCmiKeys(io, arena, root_dir, cmi_vars.get("ocamlcommon_BYTE_CMI_FILES").?),
            .ocamlbytecomp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlbytecomp_CMO_FILES").?),
            .ocamlmiddleend_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlmiddleend_CMO_FILES").?),
            .ocamlmiddleend_cmis = try normalizeCmiKeys(io, arena, root_dir, cmi_vars.get("ocamlmiddleend_BYTE_CMI_FILES").?),
            .ocamloptcomp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamloptcomp_CMO_FILES").?),
            .ocamloptcomp_cmis = try normalizeCmiKeys(io, arena, root_dir, cmi_vars.get("ocamloptcomp_BYTE_CMI_FILES").?),
            .ocamltoplevel_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamltoplevel_CMO_FILES").?),
            .ocamllex_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamllex_CMO_FILES").?),
            .ocamlprof_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlprof_CMO_FILES").?),
            .ocamlcp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlcp_CMO_FILES").?),
            .ocamloptp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamloptp_CMO_FILES").?),
            .ocamlmklib_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlmklib_CMO_FILES").?),
            .ocamlmktop_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlmktop_CMO_FILES").?),
        };
    }

    if (is_5_1_or_newer) {
        return .{
            .ocamlcommon_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("COMMON").?),
            .ocamlcommon_cmis = try normalizeCmiKeys(io, arena, root_dir, root_vars.get("COMMON_CMI").?),
            .ocamlbytecomp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("BYTECOMP").?),
            .ocamlmiddleend_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("MIDDLE_END").?),
            .ocamlmiddleend_cmis = try normalizeCmiKeys(io, arena, root_dir, root_vars.get("MIDDLE_END_CMI").?),
            .ocamloptcomp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("OPTCOMP").?),
            .ocamloptcomp_cmis = try normalizeCmiKeys(io, arena, root_dir, root_vars.get("OPTCOMP_CMI").?),
            .ocamltoplevel_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("TOPLEVEL").?),
            .ocamllex_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamllex_MODULES").?),
            .ocamlprof_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlprof_MODULES").?),
            .ocamlcp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlcp_MODULES").?),
            .ocamloptp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamloptp_MODULES").?),
            .ocamlmklib_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlmklib_MODULES").?),
            .ocamlmktop_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("ocamlmktop_MODULES").?),
        };
    }

    // OCaml 5.0: query lex/Makefile and tools/Makefile
    const lex_vars = try queryMakeVars(io, gpa, arena, src_root, "lex/Makefile", &.{
        "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{"OBJS"});
    var lex_raw: std.ArrayList([]const u8) = .empty;
    for (lex_vars.get("OBJS").?) |obj| {
        try lex_raw.append(arena, try std.fmt.allocPrint(arena, "lex/{s}", .{obj}));
    }

    const tools_vars = try queryMakeVars(io, gpa, arena, src_root, "tools/Makefile", &.{
        "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "OCAMLPROF", "OCAMLCP", "OCAMLMKLIB", "OCAMLMKTOP" });

    var cp_raw: std.ArrayList([]const u8) = .empty;
    try cp_raw.appendSlice(arena, tools_vars.get("OCAMLCP").?);
    try cp_raw.append(arena, "tools/ocamlcp.cmo");

    var optp_raw: std.ArrayList([]const u8) = .empty;
    try optp_raw.appendSlice(arena, tools_vars.get("OCAMLCP").?);
    try optp_raw.append(arena, "tools/ocamloptp.cmo");

    return .{
        .ocamlcommon_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("COMMON").?),
        .ocamlcommon_cmis = try normalizeCmiKeys(io, arena, root_dir, root_vars.get("COMMON_CMI").?),
        .ocamlbytecomp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("BYTECOMP").?),
        .ocamlmiddleend_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("MIDDLE_END").?),
        .ocamlmiddleend_cmis = try normalizeCmiKeys(io, arena, root_dir, root_vars.get("MIDDLE_END_CMI").?),
        .ocamloptcomp_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("OPTCOMP").?),
        .ocamloptcomp_cmis = try normalizeCmiKeys(io, arena, root_dir, root_vars.get("OPTCOMP_CMI").?),
        .ocamltoplevel_cmos = try normalizeCmoKeys(io, arena, root_dir, root_vars.get("TOPLEVEL").?),
        .ocamllex_cmos = try normalizeCmoKeys(io, arena, root_dir, lex_raw.items),
        .ocamlprof_cmos = try normalizeCmoKeys(io, arena, root_dir, tools_vars.get("OCAMLPROF").?),
        .ocamlcp_cmos = try normalizeCmoKeys(io, arena, root_dir, cp_raw.items),
        .ocamloptp_cmos = try normalizeCmoKeys(io, arena, root_dir, optp_raw.items),
        .ocamlmklib_cmos = try normalizeCmoKeys(io, arena, root_dir, tools_vars.get("OCAMLMKLIB").?),
        .ocamlmktop_cmos = try normalizeCmoKeys(io, arena, root_dir, tools_vars.get("OCAMLMKTOP").?),
    };
}

fn normalizeCmoKeys(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    items: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const stem = if (std.mem.endsWith(u8, item, ".cmo")) item[0 .. item.len - 4] else item;
        const resolved = try resolveVpathKey(io, arena, root_dir, stem);
        try out.append(arena, resolved);
    }
    return out.items;
}

fn normalizeCmiKeys(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    items: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const stem = if (std.mem.endsWith(u8, item, ".cmi")) item[0 .. item.len - 4] else item;
        const resolved = try resolveVpathKey(io, arena, root_dir, stem);
        try out.append(arena, resolved);
    }
    return out.items;
}

fn resolveVpathKey(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    stem: []const u8,
) ![]const u8 {
    inline for (&.{
        .{ "toplevel/topeval", "toplevel/byte/topeval" },
        .{ "toplevel/trace", "toplevel/byte/trace" },
        .{ "toplevel/topmain", "toplevel/byte/topmain" },
        .{ "config", "utils/config" },
        .{ "domainstate", "utils/domainstate" },
        .{ "camlinternalMenhirLib", "parsing/camlinternalMenhirLib" },
        .{ "parser", "parsing/parser" },
        .{ "lexer", "parsing/lexer" },
        .{ "runtimedef", "lambda/runtimedef" },
        .{ "opcodes", "bytecomp/opcodes" },
        .{ "byterntm", "bytecomp/byterntm" },
        .{ "opnames", "tools/opnames" },
    }) |entry| {
        if (std.mem.eql(u8, stem, entry[0])) return entry[1];
    }

    if (std.mem.indexOfScalar(u8, stem, '/') != null) {
        return stem;
    }

    for (core_include_dirs) |dir_name| {
        const ml_cand = try std.fmt.allocPrint(arena, "{s}/{s}.ml", .{ dir_name, stem });
        const mli_cand = try std.fmt.allocPrint(arena, "{s}/{s}.mli", .{ dir_name, stem });
        if (fileExists(io, root_dir, ml_cand) or fileExists(io, root_dir, mli_cand)) {
            return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_name, stem });
        }
    }

    std.debug.panic("resolveVpathKey failed for '{s}'", .{stem});
}

fn computeCompilerPlan(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    arch_specific: []const []const u8,
    lists: *const CompilerLists,
) !Manifest.Plan {
    // Parse .depend (and tools/.depend if present) taking union across all architectures
    const root_dep_src = try root_dir.readFileAlloc(io, ".depend", arena, .unlimited);
    var dep_map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    try parseDependUnionInto(arena, root_dep_src, "", &dep_map);

    if (root_dir.readFileAlloc(io, "tools/.depend", arena, .unlimited)) |tools_dep_src| {
        try parseDependUnionInto(arena, tools_dep_src, "tools/", &dep_map);
    } else |_| {}

    var arch_spec_set: std.StringHashMapUnmanaged(void) = .empty;
    for (arch_specific) |f| {
        try arch_spec_set.put(arena, f, {});
    }

    // Collect all required unit keys
    var cmo_keys: std.ArrayList([]const u8) = .empty;
    var cmo_key_set: std.StringHashMapUnmanaged(void) = .empty;
    var cmi_only_keys: std.ArrayList([]const u8) = .empty;
    var cmi_only_set: std.StringHashMapUnmanaged(void) = .empty;

    const addCmoKey = struct {
        fn call(a: std.mem.Allocator, list: *std.ArrayList([]const u8), set: *std.StringHashMapUnmanaged(void), k: []const u8) !void {
            if (!set.contains(k)) {
                try set.put(a, k, {});
                try list.append(a, k);
            }
        }
    }.call;

    const cmo_slices = [_][]const []const u8{
        lists.ocamlcommon_cmos,
        &.{ "utils/config_main", "utils/config_boot" },
        lists.ocamlbytecomp_cmos,
        lists.ocamlmiddleend_cmos,
        lists.ocamloptcomp_cmos,
        lists.ocamltoplevel_cmos,
        lists.ocamlprof_cmos,
        lists.ocamlcp_cmos,
        lists.ocamloptp_cmos,
        lists.ocamlmklib_cmos,
        lists.ocamlmktop_cmos,
        &.{
            "driver/main",
            "driver/optmain",
            "toplevel/topstart",
            "toplevel/expunge",
            "tools/ocamldep",
            "tools/objinfo",
            "tools/ocamlcmt",
            "tools/opnames",
            "tools/dumpobj",
            "tools/primreq",
            "tools/stripdebug",
            "tools/cmpbyt",
            "tools/profiling",
        },
    };
    for (cmo_slices) |slice| {
        for (slice) |k| try addCmoKey(arena, &cmo_keys, &cmo_key_set, k);
    }

    const cmi_slices = [_][]const []const u8{
        lists.ocamlcommon_cmis,
        lists.ocamlmiddleend_cmis,
        lists.ocamloptcomp_cmis,
    };
    for (cmi_slices) |slice| {
        for (slice) |k| {
            if (!cmo_key_set.contains(k) and !cmi_only_set.contains(k)) {
                try cmi_only_set.put(arena, k, {});
                try cmi_only_keys.append(arena, k);
            }
        }
    }

    // Transitively walk dep_map from all cmo_keys and cmi_only_keys to pull in any .mli-only or .ml dependencies
    var worklist: std.ArrayList([]const u8) = .empty;
    for (cmo_keys.items) |k| {
        try worklist.append(arena, try std.fmt.allocPrint(arena, "{s}.cmo", .{k}));
        const cmi_key = if (std.mem.startsWith(u8, k, "toplevel/byte/"))
            try std.fmt.allocPrint(arena, "toplevel/{s}", .{std.fs.path.basename(k)})
        else
            k;
        try worklist.append(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{cmi_key}));
    }
    for (cmi_only_keys.items) |k| {
        try worklist.append(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{k}));
    }

    var wi: usize = 0;
    while (wi < worklist.items.len) : (wi += 1) {
        const cur = worklist.items[wi];
        if (dep_map.get(cur)) |deps| {
            for (deps) |dep_tok| {
                if (std.mem.startsWith(u8, dep_tok, "stdlib/") or std.mem.startsWith(u8, dep_tok, "otherlibs/")) continue;
                const dep_key = dep_tok[0 .. dep_tok.len - 4]; // strip .cmi / .cmo
                if (cmo_key_set.contains(dep_key) or cmi_only_set.contains(dep_key)) continue;

                if ((try resolveMliSource(io, arena, root_dir, &arch_spec_set, dep_key)) != null) {
                    try cmi_only_set.put(arena, dep_key, {});
                    try cmi_only_keys.append(arena, dep_key);
                    try worklist.append(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{dep_key}));
                } else {
                    try cmo_key_set.put(arena, dep_key, {});
                    try cmo_keys.append(arena, dep_key);
                    try worklist.append(arena, try std.fmt.allocPrint(arena, "{s}.cmo", .{dep_key}));
                }
            }
        }
    }

    // Build the set of CMI-producing units
    var cmi_units: std.ArrayList(WaveUnit) = .empty;
    var cmi_by_basename: std.StringHashMapUnmanaged([]const u8) = .empty; // "misc.cmi" -> "utils/misc"

    for (cmi_only_keys.items) |k| {
        const mli_src = (try resolveMliSource(io, arena, root_dir, &arch_spec_set, k)) orelse continue;
        try cmi_units.append(arena, .{ .kind = .intf, .unit = compilerUnit(k, mli_src) });
        try cmi_by_basename.put(arena, try cmiName(arena, k), k);
    }

    var cmo_units: std.ArrayList(Unit) = .empty;
    for (cmo_keys.items) |k| {
        const cmi_key = if (std.mem.startsWith(u8, k, "toplevel/byte/"))
            try std.fmt.allocPrint(arena, "toplevel/{s}", .{std.fs.path.basename(k)})
        else
            k;
        const cmi_name = try cmiName(arena, k);
        const ml_src = try resolveMlSource(arena, &arch_spec_set, k);

        if (try resolveMliSource(io, arena, root_dir, &arch_spec_set, cmi_key)) |mli_src| {
            if (!cmi_by_basename.contains(cmi_name)) {
                try cmi_units.append(arena, .{ .kind = .intf, .unit = compilerUnit(cmi_key, mli_src) });
                try cmi_by_basename.put(arena, cmi_name, cmi_key);
            }
            try cmo_units.append(arena, compilerUnit(k, ml_src));
        } else {
            // No .mli: compiling the .ml produces both .cmi and .cmo, so it goes into the waves.
            try cmi_units.append(arena, .{ .kind = .impl, .unit = compilerUnit(k, ml_src) });
            try cmi_by_basename.put(arena, cmi_name, k);
        }
    }

    return .{
        .cmi_waves = try sortCmiWaves(arena, cmi_units.items, &dep_map, &cmi_by_basename),
        .cmo_units = cmo_units.items,
    };
}

fn compilerUnit(key: []const u8, src: Src) Unit {
    return .{
        .key = key,
        .name = std.fs.path.basename(key),
        .src = src,
        .archs = if (std.mem.startsWith(u8, key, "asmcomp/x86_")) intel_archs else &.{},
        .dest = if (std.mem.eql(u8, key, "tools/profiling"))
            .profiling
        else if (std.mem.startsWith(u8, key, "tools/"))
            .none
        else
            .lib,
    };
}

fn cmiName(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.cmi", .{std.fs.path.basename(key)});
}

fn computeLexPlan(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    lex_cmo_keys: []const []const u8,
) !Manifest.Plan {
    var dep_map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    const root_dep_src = try root_dir.readFileAlloc(io, ".depend", arena, .unlimited);
    try parseDependUnionInto(arena, root_dep_src, "", &dep_map);
    if (root_dir.readFileAlloc(io, "lex/.depend", arena, .unlimited)) |lex_dep_src| {
        try parseDependUnionInto(arena, lex_dep_src, "lex/", &dep_map);
    } else |_| {}

    var empty_arch: std.StringHashMapUnmanaged(void) = .empty;
    var cmi_units: std.ArrayList(WaveUnit) = .empty;
    var cmo_units: std.ArrayList(Unit) = .empty;
    var cmi_by_basename: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (lex_cmo_keys) |k| {
        const name = std.fs.path.basename(k);
        const ml_src = try resolveMlSource(arena, &empty_arch, k);
        try cmi_by_basename.put(arena, try cmiName(arena, k), k);

        if (try resolveMliSource(io, arena, root_dir, &empty_arch, k)) |mli_src| {
            try cmi_units.append(arena, .{ .kind = .intf, .unit = .{ .key = k, .name = name, .src = mli_src } });
            try cmo_units.append(arena, .{ .key = k, .name = name, .src = ml_src });
        } else {
            try cmi_units.append(arena, .{ .kind = .impl, .unit = .{ .key = k, .name = name, .src = ml_src } });
        }
    }

    return .{
        .cmi_waves = try sortCmiWaves(arena, cmi_units.items, &dep_map, &cmi_by_basename),
        .cmo_units = cmo_units.items,
    };
}

fn sortCmiWaves(
    arena: std.mem.Allocator,
    units: []const WaveUnit,
    dep_map: *const std.StringHashMapUnmanaged([]const []const u8),
    cmi_by_basename: *const std.StringHashMapUnmanaged([]const u8),
) ![]const []const WaveUnit {
    const total = units.len;
    var done = try arena.alloc(bool, total);
    @memset(done, false);
    var built_cmis: std.StringHashMapUnmanaged(void) = .empty;
    var waves: std.ArrayList([]const WaveUnit) = .empty;
    var completed: usize = 0;

    while (completed < total) {
        var wave: std.ArrayList(WaveUnit) = .empty;
        var wave_indices: std.ArrayList(usize) = .empty;

        for (units, 0..) |wu, idx| {
            if (done[idx]) continue;
            const u = wu.unit;
            const cmi_name = try std.fmt.allocPrint(arena, "{s}.cmi", .{u.name});
            const dep_lookup_key = switch (wu.kind) {
                .impl => try std.fmt.allocPrint(arena, "{s}.cmo", .{u.key}),
                .intf => try std.fmt.allocPrint(arena, "{s}.cmi", .{u.key}),
            };

            var ready = true;
            if (dep_map.get(dep_lookup_key)) |deps| {
                for (deps) |dep_tok| {
                    const dep_base = std.fs.path.basename(dep_tok);
                    const dep_cmi = if (std.mem.endsWith(u8, dep_base, ".cmo"))
                        try std.fmt.allocPrint(arena, "{s}.cmi", .{dep_base[0 .. dep_base.len - 4]})
                    else
                        dep_base;
                    if (std.mem.eql(u8, dep_cmi, cmi_name)) continue;
                    if (cmi_by_basename.contains(dep_cmi) and !built_cmis.contains(dep_cmi)) {
                        ready = false;
                        break;
                    }
                }
            }
            if (ready) {
                try wave.append(arena, wu);
                try wave_indices.append(arena, idx);
            }
        }

        if (wave.items.len == 0) {
            for (units, 0..) |wu, idx| {
                if (!done[idx]) std.log.err("Unresolved CMI wave unit: {s} ({s})", .{ wu.unit.key, wu.unit.name });
            }
            @panic("sortCmiWaves cycle detected");
        }

        for (wave_indices.items) |idx| {
            done[idx] = true;
            try built_cmis.put(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{units[idx].unit.name}), {});
            completed += 1;
        }
        try waves.append(arena, wave.items);
    }

    return waves.items;
}

fn resolveMliSource(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    arch_spec_set: *const std.StringHashMapUnmanaged(void),
    key: []const u8,
) !?Src {
    inline for (&.{
        .{ "utils/config", Src{ .upstream = "utils/config.mli" } },
        .{ "utils/config_main", Src{ .upstream = "utils/config.mli" } },
        .{ "utils/config_boot", Src{ .upstream = "utils/config.mli" } },
        .{ "utils/domainstate", Src{ .gen = .domainstate_mli } },
        .{ "parsing/camlinternalMenhirLib", Src{ .gen = .camlinternalMenhirLib_mli } },
        .{ "parsing/parser", Src{ .gen = .parser_mli } },
        .{ "bytecomp/opcodes", Src{ .gen = .opcodes_mli } },
        .{ "lex/parser", Src{ .gen = .lex_parser_mli } },
    }) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }

    const mli_rel = try std.fmt.allocPrint(arena, "{s}.mli", .{key});
    if (arch_spec_set.contains(mli_rel)) {
        return .{ .arch = try std.fmt.allocPrint(arena, "{s}.mli", .{std.fs.path.basename(key)}) };
    }
    if (fileExists(io, root_dir, mli_rel)) {
        return .{ .upstream = mli_rel };
    }
    return null;
}

fn resolveMlSource(
    arena: std.mem.Allocator,
    arch_spec_set: *const std.StringHashMapUnmanaged(void),
    key: []const u8,
) !Src {
    inline for (&.{
        .{ "utils/config", Src{ .gen = .config_main_ml } },
        .{ "utils/config_main", Src{ .gen = .config_main_ml } },
        .{ "utils/config_boot", Src{ .gen = .config_boot_ml } },
        .{ "utils/domainstate", Src{ .gen = .domainstate_ml } },
        .{ "parsing/camlinternalMenhirLib", Src{ .upstream = "boot/menhir/menhirLib.ml" } },
        .{ "parsing/parser", Src{ .gen = .parser_ml } },
        .{ "parsing/lexer", Src{ .gen = .parsing_lexer_ml } },
        .{ "bytecomp/byterntm", Src{ .gen = .byterntm_ml } },
        .{ "bytecomp/opcodes", Src{ .gen = .opcodes_ml } },
        .{ "lambda/runtimedef", Src{ .gen = .runtimedef_ml } },
        .{ "tools/opnames", Src{ .gen = .opnames_ml } },
        .{ "asmcomp/emit", Src{ .gen = .emit_ml } },
        .{ "lex/parser", Src{ .gen = .lex_parser_ml } },
        .{ "lex/lexer", Src{ .gen = .lex_lexer_ml } },
    }) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }

    const ml_rel = try std.fmt.allocPrint(arena, "{s}.ml", .{key});
    if (arch_spec_set.contains(ml_rel)) {
        return .{ .arch = try std.fmt.allocPrint(arena, "{s}.ml", .{std.fs.path.basename(key)}) };
    }
    return .{ .upstream = ml_rel };
}

fn computeDynlinkPackPlan(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root: []const u8,
    root_dir: std.Io.Dir,
) !Manifest.Plan {
    const dyn_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/dynlink/Makefile", &.{
        "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "COMPILERLIBS_INTFS", "COMPILERLIBS_SOURCES" });

    const intfs = dyn_vars.get("COMPILERLIBS_INTFS").?;
    const sources = dyn_vars.get("COMPILERLIBS_SOURCES").?;

    var empty_arch: std.StringHashMapUnmanaged(void) = .empty;
    var intf_units: std.ArrayList(Unit) = .empty;
    var cmo_units: std.ArrayList(Unit) = .empty;
    var stem_set: std.StringHashMapUnmanaged(void) = .empty;

    for (sources) |ml_rel| {
        const key = ml_rel[0 .. ml_rel.len - 3]; // strip .ml
        const stem = std.fs.path.basename(key);
        const mli_src = (try resolveMliSource(io, arena, root_dir, &empty_arch, key)).?;
        try intf_units.append(arena, .{ .key = key, .name = stem, .src = mli_src });
        try cmo_units.append(arena, .{ .key = key, .name = stem, .src = try resolveMlSource(arena, &empty_arch, key) });
        try stem_set.put(arena, stem, {});
    }

    for (intfs) |mli_rel| {
        const key = mli_rel[0 .. mli_rel.len - 4]; // strip .mli
        const stem = std.fs.path.basename(key);
        const mli_src = (try resolveMliSource(io, arena, root_dir, &empty_arch, key)).?;
        try intf_units.append(arena, .{ .key = key, .name = stem, .src = mli_src });
        // interface-only modules are compiled with `-impl` on the .mli
        try cmo_units.append(arena, .{ .key = key, .name = stem, .src = mli_src });
        try stem_set.put(arena, stem, {});
    }

    const root_dep_src = try root_dir.readFileAlloc(io, ".depend", arena, .unlimited);
    var dep_map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    try parseDependUnionInto(arena, root_dep_src, "", &dep_map);

    var bare_cmi_deps: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var map_it = dep_map.iterator();
    while (map_it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "lex/")) continue;
        if (!std.mem.endsWith(u8, entry.key_ptr.*, ".cmi")) continue;
        const base = std.fs.path.basename(entry.key_ptr.*);
        const stem = base[0 .. base.len - 4];
        var dlist: std.ArrayList([]const u8) = .empty;
        for (entry.value_ptr.*) |d| {
            if (std.mem.endsWith(u8, d, ".cmi")) {
                const dbase = std.fs.path.basename(d);
                try dlist.append(arena, dbase[0 .. dbase.len - 4]);
            }
        }
        try bare_cmi_deps.put(arena, stem, dlist.items);
    }

    const total = intf_units.items.len;
    var done = try arena.alloc(bool, total);
    @memset(done, false);
    var built: std.StringHashMapUnmanaged(void) = .empty;
    var waves: std.ArrayList([]const WaveUnit) = .empty;
    var completed: usize = 0;

    while (completed < total) {
        var wave: std.ArrayList(WaveUnit) = .empty;
        var wave_indices: std.ArrayList(usize) = .empty;

        for (intf_units.items, 0..) |u, idx| {
            if (done[idx]) continue;
            var ready = true;
            if (bare_cmi_deps.get(u.name)) |deps| {
                for (deps) |dep_stem| {
                    if (std.mem.eql(u8, dep_stem, u.name)) continue;
                    if (stem_set.contains(dep_stem) and !built.contains(dep_stem)) {
                        ready = false;
                        break;
                    }
                }
            }
            if (ready) {
                try wave.append(arena, .{ .kind = .intf, .unit = u });
                try wave_indices.append(arena, idx);
            }
        }
        if (wave.items.len == 0) @panic("Dynlink pack cycle");
        for (wave_indices.items) |idx| {
            done[idx] = true;
            try built.put(arena, intf_units.items[idx].name, {});
            completed += 1;
        }
        try waves.append(arena, wave.items);
    }

    return .{
        .cmi_waves = waves.items,
        .cmo_units = cmo_units.items,
    };
}

fn parseDependUnionInto(
    arena: std.mem.Allocator,
    depend_src: []const u8,
    subdir_prefix: []const u8,
    map: *std.StringHashMapUnmanaged([]const []const u8),
) !void {
    var joined_line: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, depend_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#") or
            std.mem.startsWith(u8, trimmed, "ifeq ") or std.mem.startsWith(u8, trimmed, "endif"))
        {
            continue;
        }

        if (std.mem.endsWith(u8, trimmed, "\\")) {
            try joined_line.appendSlice(arena, trimmed[0 .. trimmed.len - 1]);
            try joined_line.append(arena, ' ');
            continue;
        }

        try joined_line.appendSlice(arena, trimmed);
        const full = std.mem.trim(u8, joined_line.items, " \t");
        joined_line = .empty;

        const colon_idx = std.mem.indexOfScalar(u8, full, ':') orelse continue;
        const lhs = std.mem.trim(u8, full[0..colon_idx], " \t");
        const rhs = std.mem.trim(u8, full[colon_idx + 1 ..], " \t");

        var deps: std.ArrayList([]const u8) = .empty;
        var rhs_it = std.mem.tokenizeAny(u8, rhs, " \t");
        while (rhs_it.next()) |dep_tok| {
            if (std.mem.endsWith(u8, dep_tok, ".cmi") or std.mem.endsWith(u8, dep_tok, ".cmo")) {
                try deps.append(arena, try normalizeDepTok(arena, subdir_prefix, dep_tok));
            }
        }

        var lhs_it = std.mem.tokenizeAny(u8, lhs, " \t");
        while (lhs_it.next()) |target_tok| {
            if (std.mem.endsWith(u8, target_tok, ".cmi") or std.mem.endsWith(u8, target_tok, ".cmo")) {
                const norm_t = try normalizeDepTok(arena, subdir_prefix, target_tok);
                if (map.get(norm_t)) |existing| {
                    var merged: std.ArrayList([]const u8) = .empty;
                    try merged.appendSlice(arena, existing);
                    for (deps.items) |d| {
                        var found = false;
                        for (existing) |e| {
                            if (std.mem.eql(u8, e, d)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) try merged.append(arena, d);
                    }
                    try map.put(arena, norm_t, merged.items);
                } else {
                    try map.put(arena, norm_t, deps.items);
                }
            }
        }
    }
}

fn normalizeDepTok(arena: std.mem.Allocator, subdir_prefix: []const u8, tok: []const u8) ![]const u8 {
    if (subdir_prefix.len == 0) return tok;
    if (std.mem.startsWith(u8, tok, "../")) return tok["../".len..];
    if (std.mem.indexOfScalar(u8, tok, '/') == null) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ subdir_prefix, tok });
    }
    return tok;
}

fn stdlibModuleName(arena: std.mem.Allocator, basename: []const u8) ![]const u8 {
    if (std.mem.eql(u8, basename, "stdlib") or std.mem.startsWith(u8, basename, "camlinternal")) {
        return basename;
    }
    var cap = try arena.dupe(u8, basename);
    cap[0] = std.ascii.toUpper(cap[0]);
    return std.fmt.allocPrint(arena, "stdlib__{s}", .{cap});
}

fn evalCompflagsScript(arena: std.mem.Allocator, script: []const u8, target: []const u8) ![]const []const u8 {
    var lines = std.mem.splitScalar(u8, script, '\n');
    var in_case = false;
    var joined_line: std.ArrayList(u8) = .empty;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!in_case) {
            if (std.mem.startsWith(u8, line, "case ")) in_case = true;
            continue;
        }
        if (std.mem.eql(u8, line, "esac")) break;

        if (std.mem.endsWith(u8, line, "\\")) {
            try joined_line.appendSlice(arena, line[0 .. line.len - 1]);
            try joined_line.append(arena, ' ');
            continue;
        }
        try joined_line.appendSlice(arena, line);
        if (!std.mem.endsWith(u8, joined_line.items, ";;")) {
            try joined_line.append(arena, ' ');
            continue;
        }

        const arm = std.mem.trim(u8, joined_line.items, " \t");
        joined_line = .empty;

        const paren_idx = std.mem.indexOfScalar(u8, arm, ')') orelse continue;
        const patterns_str = std.mem.trim(u8, arm[0..paren_idx], " \t");
        const body_with_semi = std.mem.trim(u8, arm[paren_idx + 1 ..], " \t");
        const body = std.mem.trim(u8, body_with_semi[0 .. body_with_semi.len - 2], " \t");
        const echo_arg = if (std.mem.startsWith(u8, body, "echo ")) body["echo ".len..] else "";

        var pat_it = std.mem.splitScalar(u8, patterns_str, '|');
        while (pat_it.next()) |raw_pat| {
            const pat = std.mem.trim(u8, raw_pat, " \t");
            if (globMatch(pat, target)) {
                var cleaned = echo_arg;
                if (std.mem.indexOf(u8, cleaned, "-pp ")) |pp_idx| {
                    cleaned = std.mem.trim(u8, cleaned[0..pp_idx], " \t\"'");
                }
                var flags: std.ArrayList([]const u8) = .empty;
                var tok_it = std.mem.tokenizeAny(u8, cleaned, " \t\"'");
                while (tok_it.next()) |tok| try flags.append(arena, tok);
                return flags.items;
            }
        }
    }
    return &.{};
}

fn globMatch(pat: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pat.len and pat[pi] == '[') {
            if (std.mem.indexOfScalarPos(u8, pat, pi + 1, ']')) |close_idx| {
                if (std.mem.indexOfScalar(u8, pat[pi + 1 .. close_idx], text[ti]) != null) {
                    pi = close_idx + 1;
                    ti += 1;
                    continue;
                }
            }
        } else if (pi < pat.len and (pat[pi] == '?' or pat[pi] == text[ti])) {
            pi += 1;
            ti += 1;
            continue;
        } else if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            pi += 1;
            star_ti = ti;
            continue;
        }
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
            continue;
        }
        return false;
    }
    while (pi < pat.len and pat[pi] == '*') : (pi += 1) {}
    return pi == pat.len;
}

fn parseStdlibDependCmiMap(
    arena: std.mem.Allocator,
    depend_src: []const u8,
) !std.StringHashMapUnmanaged([]const []const u8) {
    var map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var joined_line: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, depend_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.endsWith(u8, line, "\\")) {
            try joined_line.appendSlice(arena, line[0 .. line.len - 1]);
            try joined_line.append(arena, ' ');
            continue;
        }
        try joined_line.appendSlice(arena, line);
        const full = std.mem.trim(u8, joined_line.items, " \t");
        joined_line = .empty;

        const colon_idx = std.mem.indexOfScalar(u8, full, ':') orelse continue;
        const lhs = std.mem.trim(u8, full[0..colon_idx], " \t");
        const rhs = std.mem.trim(u8, full[colon_idx + 1 ..], " \t");

        var deps: std.ArrayList([]const u8) = .empty;
        var rhs_it = std.mem.tokenizeAny(u8, rhs, " \t");
        while (rhs_it.next()) |dep_tok| {
            if (std.mem.endsWith(u8, dep_tok, ".cmi")) {
                try deps.append(arena, dep_tok[0 .. dep_tok.len - 4]);
            }
        }

        var lhs_it = std.mem.tokenizeAny(u8, lhs, " \t");
        while (lhs_it.next()) |target_tok| {
            if (std.mem.endsWith(u8, target_tok, ".cmi")) {
                try map.put(arena, target_tok[0 .. target_tok.len - 4], deps.items);
            }
        }
    }
    return map;
}

const StdlibPlan = struct {
    plan: Manifest.Plan,
    /// module names archived into stdlib.cma, in link order
    cma: []const []const u8,
};

fn computeStdlibPlan(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    basenames: []const []const u8,
) !StdlibPlan {
    const compflags_script = try root_dir.readFileAlloc(io, "stdlib/Compflags", arena, .unlimited);
    const stdlib_depend = try root_dir.readFileAlloc(io, "stdlib/.depend", arena, .unlimited);
    const cmi_dep_map = try parseStdlibDependCmiMap(arena, stdlib_depend);

    var wave_units: std.ArrayList(WaveUnit) = .empty;
    var cmo_units: std.ArrayList(Unit) = .empty;
    var cma: std.ArrayList([]const u8) = .empty;

    for (basenames) |base| {
        const mod_name = try stdlibModuleName(arena, base);
        const is_stdlib = std.mem.eql(u8, base, "stdlib");
        const is_labels = std.mem.endsWith(u8, base, "Labels");
        const cmi_flags = try evalCompflagsScript(arena, compflags_script, try std.fmt.allocPrint(arena, "{s}.cmi", .{mod_name}));
        const cmo_flags = try evalCompflagsScript(arena, compflags_script, try std.fmt.allocPrint(arena, "{s}.cmo", .{mod_name}));
        const cmx_flags = try evalCompflagsScript(arena, compflags_script, try std.fmt.allocPrint(arena, "{s}.cmx", .{mod_name}));

        const ml_rel = try std.fmt.allocPrint(arena, "stdlib/{s}.ml", .{base});
        const mli_rel = try std.fmt.allocPrint(arena, "stdlib/{s}.mli", .{base});
        const ml_src: Src = if (std.mem.eql(u8, base, "sys"))
            .{ .gen = .stdlib_sys_ml }
        else if (is_stdlib)
            .{ .expanded = ml_rel }
        else
            .{ .upstream = ml_rel };

        if (fileExists(io, root_dir, mli_rel)) {
            const mli_src: Src = if (is_stdlib or is_labels) .{ .expanded = mli_rel } else .{ .upstream = mli_rel };
            try wave_units.append(arena, .{ .kind = .intf, .unit = .{
                .key = mod_name,
                .name = mod_name,
                .src = mli_src,
                .flags = cmi_flags,
                .dest = .lib,
            } });
            try cmo_units.append(arena, .{
                .key = mod_name,
                .name = mod_name,
                .src = ml_src,
                .flags = cmo_flags,
                .native_flags = cmx_flags,
                .dest = .lib,
            });
        } else {
            try wave_units.append(arena, .{ .kind = .impl, .unit = .{
                .key = mod_name,
                .name = mod_name,
                .src = ml_src,
                .flags = cmi_flags,
                .native_flags = cmx_flags,
                .dest = .lib,
            } });
        }
        try cma.append(arena, mod_name);
    }

    // std_exit is not part of stdlib.cma; it is linked last into every executable.
    const std_exit_flags = try evalCompflagsScript(arena, compflags_script, "std_exit.cmo");
    if (fileExists(io, root_dir, "stdlib/std_exit.mli")) {
        try wave_units.append(arena, .{ .kind = .intf, .unit = .{
            .key = "std_exit",
            .name = "std_exit",
            .src = .{ .upstream = "stdlib/std_exit.mli" },
            .flags = std_exit_flags,
            .dest = .lib,
        } });
    }
    try cmo_units.append(arena, .{
        .key = "std_exit",
        .name = "std_exit",
        .src = .{ .upstream = "stdlib/std_exit.ml" },
        .flags = std_exit_flags,
        .native_flags = try evalCompflagsScript(arena, compflags_script, "std_exit.cmx"),
        .dest = .lib,
    });

    return .{
        .plan = .{
            .cmi_waves = try computeStdlibCmiWaves(arena, wave_units.items, &cmi_dep_map),
            .cmo_units = cmo_units.items,
        },
        .cma = cma.items,
    };
}

fn computeStdlibCmiWaves(
    arena: std.mem.Allocator,
    units: []const WaveUnit,
    cmi_dep_map: *const std.StringHashMapUnmanaged([]const []const u8),
) ![]const []const WaveUnit {
    const total = units.len;
    var done = try arena.alloc(bool, total);
    @memset(done, false);
    var built: std.StringHashMapUnmanaged(void) = .empty;
    var waves: std.ArrayList([]const WaveUnit) = .empty;
    var completed: usize = 0;

    while (completed < total) {
        var wave: std.ArrayList(WaveUnit) = .empty;
        var wave_indices: std.ArrayList(usize) = .empty;

        for (units, 0..) |wu, idx| {
            if (done[idx]) continue;
            const mod_name = wu.unit.name;
            var ready = true;
            // everything but these two is compiled with the `Stdlib` module opened
            if (!std.mem.eql(u8, mod_name, "camlinternalFormatBasics") and !std.mem.eql(u8, mod_name, "stdlib")) {
                if (!built.contains("stdlib")) ready = false;
            }
            if (ready) {
                if (cmi_dep_map.get(mod_name)) |deps| {
                    for (deps) |dep_mod| {
                        if (!built.contains(dep_mod)) {
                            ready = false;
                            break;
                        }
                    }
                }
            }
            if (ready) {
                try wave.append(arena, wu);
                try wave_indices.append(arena, idx);
            }
        }
        if (wave.items.len == 0) @panic("Stdlib .depend cycle");
        for (wave_indices.items) |idx| {
            done[idx] = true;
            try built.put(arena, units[idx].unit.name, {});
            completed += 1;
        }
        try waves.append(arena, wave.items);
    }

    return waves.items;
}

fn parseSimpleMakefileVar(arena: std.mem.Allocator, src: []const u8, var_name: []const u8) ![]const []const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var found = false;
    var body: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!found) {
            if (std.mem.startsWith(u8, line, var_name)) {
                const after = std.mem.trimStart(u8, line[var_name.len..], " \t");
                if (std.mem.startsWith(u8, after, "=")) {
                    found = true;
                    const rhs = std.mem.trimStart(u8, after[1..], " \t");
                    if (std.mem.endsWith(u8, rhs, "\\")) {
                        try body.appendSlice(arena, rhs[0 .. rhs.len - 1]);
                        try body.append(arena, ' ');
                    } else {
                        try body.appendSlice(arena, rhs);
                        break;
                    }
                }
            }
        } else {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.endsWith(u8, trimmed, "\\")) {
                try body.appendSlice(arena, trimmed[0 .. trimmed.len - 1]);
                try body.append(arena, ' ');
            } else {
                try body.appendSlice(arena, trimmed);
                break;
            }
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, body.items, " \t");
    while (it.next()) |tok| try out.append(arena, tok);
    return out.items;
}

fn parseOcamlVersion(arena: std.mem.Allocator, version_m4: []const u8, version_file: []const u8) !Manifest.Version {
    const dev_str = extractM4Define(version_m4, "OCAML__DEVELOPMENT_VERSION") orelse @panic("Missing OCAML__DEVELOPMENT_VERSION");
    const major = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__VERSION_MAJOR").?, 10);
    const minor = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__VERSION_MINOR").?, 10);
    const patchlevel = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__VERSION_PATCHLEVEL").?, 10);
    const release_number: ?u32 = if (extractM4Define(version_m4, "OCAML__RELEASE_NUMBER")) |rn|
        try std.fmt.parseInt(u32, rn, 10)
    else
        null;
    const extra = extractM4Define(version_m4, "OCAML__VERSION_EXTRA") orelse "";
    const extra_prefix = extractM4Define(version_m4, "OCAML__VERSION_EXTRA_PREFIX") orelse "+";
    const version_string = if (extra.len == 0)
        try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ major, minor, patchlevel })
    else
        try std.fmt.allocPrint(arena, "{d}.{d}.{d}{s}{s}", .{ major, minor, patchlevel, extra_prefix, extra });

    const first_line = std.mem.trim(u8, std.mem.sliceTo(version_file, '\n'), " \t\r");
    if (!std.mem.eql(u8, first_line, version_string)) @panic("VERSION mismatch");

    const magic: ?Manifest.Magic = if (extractM4Define(version_m4, "MAGIC_NUMBER__PREFIX")) |prefix| blk: {
        const ver = extractM4Define(version_m4, "MAGIC_NUMBER__VERSION").?;
        const exec_format = extractM4Define(version_m4, "EXEC__FORMAT").?;
        break :blk .{
            .prefix = prefix,
            .version = ver,
            .exec_format = exec_format,
            .exec_length = prefix.len + exec_format.len + ver.len,
            .numbers = .{
                .exec = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "EXEC"),
                .cmi = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMI"),
                .cmo = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMO"),
                .cma = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMA"),
                .cmx_clambda = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMX_CLAMBDA"),
                .cmxa_clambda = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMXA_CLAMBDA"),
                .ast_impl = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "AST_IMPL"),
                .ast_intf = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "AST_INTF"),
                .cmxs = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMXS"),
                .cmt = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "CMT"),
                .linear = try extractMagicNumber(arena, version_m4, prefix, ver, exec_format, "LINEAR"),
            },
        };
    } else null;

    return .{
        .string = version_string,
        .major = major,
        .minor = minor,
        .patchlevel = patchlevel,
        .release_number = release_number,
        .dev = std.mem.eql(u8, dev_str, "true"),
        .extra = extra,
        .extra_prefix = extra_prefix,
        .number = major * 10000 + minor * 100 + patchlevel,
        .magic = magic,
    };
}

fn extractM4Define(src: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "m4_define(")) {
            const inner = line["m4_define(".len..];
            const after_key = if (std.mem.startsWith(u8, inner, "[")) blk: {
                const k_end = std.mem.indexOfScalar(u8, inner[1..], ']') orelse continue;
                const k = inner[1 .. 1 + k_end];
                if (!std.mem.eql(u8, k, key)) continue;
                break :blk inner[1 + k_end + 1 ..];
            } else blk: {
                const k_end = std.mem.indexOfScalar(u8, inner, ',') orelse continue;
                const k = std.mem.trim(u8, inner[0..k_end], " \t");
                if (!std.mem.eql(u8, k, key)) continue;
                break :blk inner[k_end..];
            };

            const comma_idx = std.mem.indexOfScalar(u8, after_key, ',') orelse continue;
            const rhs = std.mem.trimStart(u8, after_key[comma_idx + 1 ..], " \t");
            if (std.mem.startsWith(u8, rhs, "[")) {
                const val_end = std.mem.indexOfScalar(u8, rhs[1..], ']') orelse continue;
                return rhs[1 .. 1 + val_end];
            }
        }
    }
    return null;
}

fn extractMagicNumber(
    arena: std.mem.Allocator,
    version_m4: []const u8,
    prefix: []const u8,
    ver: []const u8,
    exec_fmt: []const u8,
    kind: []const u8,
) ![]const u8 {
    var lines = std.mem.splitScalar(u8, version_m4, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "DEFINE_MAGIC_NUMBER([")) {
            const inner = line["DEFINE_MAGIC_NUMBER([".len..];
            const k_end = std.mem.indexOfScalar(u8, inner, ']') orelse continue;
            if (!std.mem.eql(u8, inner[0..k_end], kind)) continue;
            const rest = std.mem.trim(u8, inner[k_end + 1 ..], " \t,");
            if (std.mem.startsWith(u8, rest, "[")) {
                const c_end = std.mem.indexOfScalar(u8, rest[1..], ']') orelse continue;
                return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, rest[1 .. 1 + c_end], ver });
            } else if (std.mem.startsWith(u8, rest, "EXEC__FORMAT")) {
                return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, exec_fmt, ver });
            }
        }
    }
    @panic("Magic number not found");
}

fn fileExists(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    if (dir.openFile(io, sub_path, .{})) |f| {
        f.close(io);
        return true;
    } else |_| return false;
}
