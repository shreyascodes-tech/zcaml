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

    // 2. Query root Makefile and Makefile.build_config.in via `make -s -n clean`
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
        "ocamlyacc_OTHER_MODULES",
        "STDLIB_MODULE_BASENAMES",
        "PERVASIVES",
        "ARCH_SPECIFIC",
        "ocamlcommon_CMO_FILES",
        "ocamlcommon_BYTE_CMI_FILES",
        "ocamlbytecomp_CMO_FILES",
        "ocamlmiddleend_CMO_FILES",
        "ocamlmiddleend_BYTE_CMI_FILES",
        "ocamloptcomp_CMO_FILES",
        "ocamloptcomp_BYTE_CMI_FILES",
        "ocamltoplevel_CMO_FILES",
        "ocamllex_CMO_FILES",
        "ocamlprof_CMO_FILES",
        "ocamlcp_CMO_FILES",
        "ocamloptp_CMO_FILES",
        "ocamlmklib_CMO_FILES",
        "ocamlmktop_CMO_FILES",
        "ocamldebug_DEBUGGER_OBJECTS",
        "odoc_info_CMO_FILES",
        "ocamldoc_CMO_FILES",
        "OCAMLDOC_LIBMLIS",
    });

    const bc_vars = try queryMakeVars(io, gpa, arena, src_root, "Makefile.build_config.in", &.{
        "ROOTDIR=.",
    }, &.{"OC_COMMON_COMPFLAGS"});

    // 3. Query stdlib and otherlibs Makefiles
    const stdlib_basenames = root_vars.get("STDLIB_MODULE_BASENAMES").?;
    const stdlib_plan = try computeStdlibPlan(io, gpa, arena, src_root, root_dir, stdlib_basenames);

    const unix_unix_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/unix/Makefile", &.{
        "UNIX_OR_WIN32=unix", "EXTRACAMLFLAGS=", "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "COMMON_C_SOURCES", "OS_C_SOURCES", "HEADERS" });

    const unix_win32_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/unix/Makefile", &.{
        "UNIX_OR_WIN32=win32", "EXTRACAMLFLAGS=", "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{"OS_C_SOURCES"});

    const str_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/str/Makefile", &.{
        "EXTRACAMLFLAGS=", "O=c", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "C_SOURCES", "COMPFLAGS" });

    const re_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/runtime_events/Makefile", &.{
        "EXTRACAMLFLAGS=", "O=c", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{ "C_SOURCES", "HEADERS" });

    const threads_vars = try queryMakeVars(io, gpa, arena, src_root, "otherlibs/systhreads/Makefile", &.{
        "EXTRACAMLFLAGS=", "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, &.{"COMPFLAGS"});

    // 4. Runtime C sources
    const rt_common = root_vars.get("runtime_COMMON_C_SOURCES").?;
    const rt_unix = if (root_vars.get("runtime_UNIX_C_SOURCES")) |s| (if (s.len > 0) s else &[_][]const u8{"unix"}) else &[_][]const u8{"unix"};
    const rt_win32 = if (root_vars.get("runtime_WIN32_C_SOURCES")) |s| (if (s.len > 0) s else &[_][]const u8{"win32"}) else &[_][]const u8{"win32"};
    const rt_byt = root_vars.get("runtime_BYTECODE_ONLY_C_SOURCES").?;
    const rt_nat = root_vars.get("runtime_NATIVE_ONLY_C_SOURCES").?;

    const yacc_raw = root_vars.get("ocamlyacc_OTHER_MODULES").?;
    var ocamlyacc_c_sources: std.ArrayList([]const u8) = .empty;
    for (yacc_raw) |item| {
        if (std.mem.endsWith(u8, item, ".c")) {
            try ocamlyacc_c_sources.append(arena, item);
        } else {
            try ocamlyacc_c_sources.append(arena, try std.fmt.allocPrint(arena, "{s}.c", .{item}));
        }
    }

    var pervasives: std.ArrayList([]const u8) = .empty;
    try pervasives.appendSlice(arena, stdlib_plan.cma);
    for (root_vars.get("PERVASIVES").?) |p| {
        if (!containsStr(pervasives.items, p)) try pervasives.append(arena, p);
    }

    // 5. Compiler & Tools module lists and waves
    const arch_specific = root_vars.get("ARCH_SPECIFIC").?;
    const comp_lists: CompilerLists = .{
        .ocamlcommon_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlcommon_CMO_FILES").?, ".cmo"),
        .ocamlcommon_cmis = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlcommon_BYTE_CMI_FILES").?, ".cmi"),
        .ocamlbytecomp_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlbytecomp_CMO_FILES").?, ".cmo"),
        .ocamlmiddleend_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlmiddleend_CMO_FILES").?, ".cmo"),
        .ocamlmiddleend_cmis = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlmiddleend_BYTE_CMI_FILES").?, ".cmi"),
        .ocamloptcomp_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamloptcomp_CMO_FILES").?, ".cmo"),
        .ocamloptcomp_cmis = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamloptcomp_BYTE_CMI_FILES").?, ".cmi"),
        .ocamltoplevel_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamltoplevel_CMO_FILES").?, ".cmo"),
        .ocamllex_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamllex_CMO_FILES").?, ".cmo"),
        .ocamlprof_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlprof_CMO_FILES").?, ".cmo"),
        .ocamlcp_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlcp_CMO_FILES").?, ".cmo"),
        .ocamloptp_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamloptp_CMO_FILES").?, ".cmo"),
        .ocamlmklib_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlmklib_CMO_FILES").?, ".cmo"),
        .ocamlmktop_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamlmktop_CMO_FILES").?, ".cmo"),
    };

    const compiler_plan = try computeCompilerPlan(io, arena, root_dir, arch_specific, &comp_lists);
    const lex_plan = try computeSubdirPlan(io, arena, root_dir, comp_lists.ocamllex_cmos, &.{}, &.{}, &.{}, true);

    const debugger_packed = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamldebug_DEBUGGER_OBJECTS").?, ".cmo");
    const debugger_plan = try computeSubdirPlan(io, arena, root_dir, debugger_packed, &.{"debugger/parser_aux"}, &.{ "-for-pack", "ocamldebug" }, &.{}, false);

    const odoc_info_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("odoc_info_CMO_FILES").?, ".cmo");
    const ocamldoc_cmos = try normalizeKeys(io, arena, root_dir, root_vars.get("ocamldoc_CMO_FILES").?, ".cmo");
    const ocamldoc_lib_keys = try normalizeKeys(io, arena, root_dir, root_vars.get("OCAMLDOC_LIBMLIS").?, ".mli");
    var all_odoc_cmos: std.ArrayList([]const u8) = .empty;
    try all_odoc_cmos.appendSlice(arena, odoc_info_cmos);
    try all_odoc_cmos.appendSlice(arena, ocamldoc_cmos);
    try all_odoc_cmos.append(arena, "ocamldoc/odoc_test");
    const ocamldoc_plan = try computeSubdirPlan(io, arena, root_dir, all_odoc_cmos.items, &.{}, &.{}, ocamldoc_lib_keys, true);

    // 6. Serialize Manifest as ZON
    const manifest: Manifest = .{
        .version = ver,
        .runtime = .{
            .common_c_sources = rt_common,
            .unix_c_sources = rt_unix,
            .win32_c_sources = rt_win32,
            .bytecode_only_c_sources = rt_byt,
            .native_only_c_sources = rt_nat,
            .ocamlyacc_c_sources = ocamlyacc_c_sources.items,
        },
        .stdlib = .{
            .compflags = stdlib_plan.compflags,
            .plan = stdlib_plan.plan,
            .cma = stdlib_plan.cma,
            .pervasives = pervasives.items,
        },
        .compiler = .{
            .compflags = bc_vars.get("OC_COMMON_COMPFLAGS").?,
            .plan = compiler_plan,
            .ocamlcommon = comp_lists.ocamlcommon_cmos,
            .ocamlbytecomp = comp_lists.ocamlbytecomp_cmos,
            .ocamlmiddleend = comp_lists.ocamlmiddleend_cmos,
            .ocamloptcomp = comp_lists.ocamloptcomp_cmos,
            .ocamltoplevel = comp_lists.ocamltoplevel_cmos,
            .ocamltoplevel_native = try nativeToplevelKeys(arena, comp_lists.ocamltoplevel_cmos),
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
        .debugger = .{
            .plan = debugger_plan,
            .packed_units = debugger_packed,
        },
        .ocamldoc = .{
            .plan = ocamldoc_plan,
            .odoc_info = odoc_info_cmos,
            .ocamldoc = ocamldoc_cmos,
        },
        .otherlibs = .{
            .compflags = str_vars.get("COMPFLAGS").?,
            .systhreads_compflags = threads_vars.get("COMPFLAGS").?,
            .unix_common_c_sources = unix_unix_vars.get("COMMON_C_SOURCES").?,
            .unix_unix_c_sources = unix_unix_vars.get("OS_C_SOURCES").?,
            .unix_win32_c_sources = unix_win32_vars.get("OS_C_SOURCES").?,
            .unix_headers = unix_unix_vars.get("HEADERS").?,
            .str_c_sources = str_vars.get("C_SOURCES").?,
            .runtime_events_c_sources = re_vars.get("C_SOURCES").?,
            .runtime_events_headers = re_vars.get("HEADERS").?,
            .threads_header = "otherlibs/systhreads/caml/threads.h",
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
    var stdin_buf: std.ArrayList(u8) = .empty;
    for (var_names) |vname| {
        try stdin_buf.appendSlice(arena, try std.fmt.allocPrint(arena, "$(info ZCAML:{s}=$({s}))\n", .{ vname, vname }));
    }
    return queryMakeRaw(io, gpa, arena, src_root, makefile_rel, make_overrides, stdin_buf.items);
}

fn queryMakeRaw(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root: []const u8,
    makefile_rel: []const u8,
    make_overrides: []const []const u8,
    stdin_lines: []const u8,
) !std.StringHashMapUnmanaged([]const []const u8) {
    const dir_rel = std.fs.path.dirname(makefile_rel) orelse "";
    const work_dir = if (dir_rel.len > 0)
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_root, dir_rel })
    else
        src_root;
    const mf_base = std.fs.path.basename(makefile_rel);

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
        try stdin_file.writeStreamingAll(io, stdin_lines);
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
        var val_str = rest[eq_idx + 1 ..];
        if (std.mem.indexOf(u8, val_str, "-pp ")) |pp_idx| {
            val_str = val_str[0..pp_idx];
        }

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

fn normalizeKeys(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    items: []const []const u8,
    ext: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const stem = if (std.mem.endsWith(u8, item, ext)) item[0 .. item.len - ext.len] else item;
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
    const root_dep_src = try root_dir.readFileAlloc(io, ".depend", arena, .unlimited);
    var dep_map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    try parseDependUnionInto(arena, root_dep_src, "", &dep_map);

    var arch_spec_set: std.StringHashMapUnmanaged(void) = .empty;
    for (arch_specific) |f| {
        try arch_spec_set.put(arena, f, {});
    }

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
        &.{ "utils/config_main" },
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
        &.{"toplevel/native/tophooks"},
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

    var cmi_units: std.ArrayList(WaveUnit) = .empty;
    var cmi_by_basename: std.StringHashMapUnmanaged([]const u8) = .empty;

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
            try cmi_units.append(arena, .{ .kind = .impl, .unit = compilerUnit(k, ml_src) });
            try cmi_by_basename.put(arena, cmi_name, k);
        }
    }

    return .{
        .cmi_waves = try sortCmiWaves(arena, cmi_units.items, &dep_map, &cmi_by_basename),
        .cmo_units = cmo_units.items,
        .cmx_waves = try nativeWaves(arena, cmi_units.items, cmo_units.items, &dep_map, true),
    };
}

fn nativeToplevelKeys(arena: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (keys) |key| {
        if (std.mem.startsWith(u8, key, "toplevel/byte/")) {
            if (std.mem.endsWith(u8, key, "/topeval")) try out.append(arena, "toplevel/native/tophooks");
            try out.append(arena, try std.fmt.allocPrint(arena, "toplevel/native/{s}", .{std.fs.path.basename(key)}));
        } else try out.append(arena, key);
    }
    return out.items;
}

fn nativeWaves(arena: std.mem.Allocator, cmis: []const WaveUnit, cmos: []const Unit, deps: *const std.StringHashMapUnmanaged([]const []const u8), compiler_plan: bool) ![]const []const Unit {
    var units: std.ArrayList(Unit) = .empty;
    for (cmis) |wu| if (wu.kind == .impl) {
        try units.append(arena, wu.unit);
    };
    for (cmos) |original| {
        var u = original;
        if (compiler_plan and std.mem.startsWith(u8, u.key, "toplevel/byte/")) {
            u.key = try std.fmt.allocPrint(arena, "toplevel/native/{s}", .{u.name});
            u.src = .{ .upstream = try std.fmt.allocPrint(arena, "{s}.ml", .{u.key}) };
        }
        try units.append(arena, u);
    }
    if (compiler_plan) try units.append(arena, compilerUnit("toplevel/native/tophooks", .{ .upstream = "toplevel/native/tophooks.ml" }));
    var pending: std.StringHashMapUnmanaged(void) = .empty;
    for (units.items) |u| try pending.put(arena, try std.fmt.allocPrint(arena, "{s}.cmx", .{u.key}), {});
    var waves: std.ArrayList([]const Unit) = .empty;
    while (pending.count() != 0) {
        var wave: std.ArrayList(Unit) = .empty;
        for (units.items) |u| {
            const key = try std.fmt.allocPrint(arena, "{s}.cmx", .{u.key});
            if (!pending.contains(key)) continue;
            var ready = true;
            if (deps.get(key)) |imports| for (imports) |dep| {
                const actual = if (compiler_plan and (std.mem.eql(u8, dep, "toplevel/topmain.cmi") or std.mem.eql(u8, dep, "toplevel/topeval.cmi") or std.mem.eql(u8, dep, "toplevel/trace.cmi")))
                    try std.fmt.allocPrint(arena, "toplevel/native/{s}.cmx", .{std.fs.path.stem(dep)})
                else if (compiler_plan and std.mem.startsWith(u8, u.key, "toplevel/") and !std.mem.startsWith(u8, u.key, "toplevel/byte/") and std.mem.startsWith(u8, dep, "toplevel/byte/"))
                    try std.fmt.allocPrint(arena, "toplevel/native/{s}", .{std.fs.path.basename(dep)})
                else
                    dep;
                if (!std.mem.eql(u8, key, actual) and pending.contains(actual)) {
                    ready = false;
                    break;
                }
            };
            if (ready) try wave.append(arena, u);
        }
        if (wave.items.len == 0) @panic("native implementation dependency cycle");
        for (wave.items) |u| _ = pending.remove(try std.fmt.allocPrint(arena, "{s}.cmx", .{u.key}));
        try waves.append(arena, wave.items);
    }
    return waves.items;
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

fn computeSubdirPlan(
    io: std.Io,
    arena: std.mem.Allocator,
    root_dir: std.Io.Dir,
    cmo_keys: []const []const u8,
    extra_cmi_keys: []const []const u8,
    cmo_flags: []const []const u8,
    lib_keys: []const []const u8,
    with_native: bool,
) !Manifest.Plan {
    var dep_map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    const root_dep_src = try root_dir.readFileAlloc(io, ".depend", arena, .unlimited);
    try parseDependUnionInto(arena, root_dep_src, "", &dep_map);

    var empty_arch: std.StringHashMapUnmanaged(void) = .empty;
    var cmi_units: std.ArrayList(WaveUnit) = .empty;
    var cmo_units: std.ArrayList(Unit) = .empty;
    var cmi_by_basename: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (extra_cmi_keys) |k| {
        const name = std.fs.path.basename(k);
        const mli_src = (try resolveMliSource(io, arena, root_dir, &empty_arch, k)).?;
        try cmi_by_basename.put(arena, try cmiName(arena, k), k);
        try cmi_units.append(arena, .{ .kind = .intf, .unit = .{ .key = k, .name = name, .src = mli_src, .flags = cmo_flags } });
    }

    for (cmo_keys) |k| {
        const name = std.fs.path.basename(k);
        const ml_src = try resolveMlSource(arena, &empty_arch, k);
        const dest: Manifest.Dest = if (containsStr(lib_keys, k)) .lib else .none;
        try cmi_by_basename.put(arena, try cmiName(arena, k), k);

        if (try resolveMliSource(io, arena, root_dir, &empty_arch, k)) |mli_src| {
            try cmi_units.append(arena, .{ .kind = .intf, .unit = .{ .key = k, .name = name, .src = mli_src, .flags = cmo_flags, .dest = dest } });
            try cmo_units.append(arena, .{ .key = k, .name = name, .src = ml_src, .flags = cmo_flags, .dest = dest });
        } else {
            try cmi_units.append(arena, .{ .kind = .impl, .unit = .{ .key = k, .name = name, .src = ml_src, .flags = cmo_flags, .dest = dest } });
        }
    }

    return .{
        .cmi_waves = try sortCmiWaves(arena, cmi_units.items, &dep_map, &cmi_by_basename),
        .cmo_units = cmo_units.items,
        .cmx_waves = if (with_native) try nativeWaves(arena, cmi_units.items, cmo_units.items, &dep_map, false) else &.{},
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
        .{ "utils/domainstate", Src{ .gen = .domainstate_mli } },
        .{ "parsing/camlinternalMenhirLib", Src{ .gen = .camlinternalMenhirLib_mli } },
        .{ "parsing/parser", Src{ .gen = .parser_mli } },
        .{ "bytecomp/opcodes", Src{ .gen = .opcodes_mli } },
        .{ "lex/parser", Src{ .gen = .lex_parser_mli } },
        .{ "debugger/debugger_parser", Src{ .gen = .debugger_parser_mli } },
        .{ "ocamldoc/odoc_text_parser", Src{ .gen = .odoc_text_parser_mli } },
        .{ "ocamldoc/odoc_parser", Src{ .gen = .odoc_parser_mli } },
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
        .{ "debugger/debugger_parser", Src{ .gen = .debugger_parser_ml } },
        .{ "debugger/debugger_lexer", Src{ .gen = .debugger_lexer_ml } },
        .{ "ocamldoc/odoc_text_parser", Src{ .gen = .odoc_text_parser_ml } },
        .{ "ocamldoc/odoc_parser", Src{ .gen = .odoc_parser_ml } },
        .{ "ocamldoc/odoc_text_lexer", Src{ .gen = .odoc_text_lexer_ml } },
        .{ "ocamldoc/odoc_lexer", Src{ .gen = .odoc_lexer_ml } },
        .{ "ocamldoc/odoc_see_lexer", Src{ .gen = .odoc_see_lexer_ml } },
        .{ "ocamldoc/odoc_ocamlhtml", Src{ .gen = .odoc_ocamlhtml_ml } },
    }) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }

    const ml_rel = try std.fmt.allocPrint(arena, "{s}.ml", .{key});
    if (arch_spec_set.contains(ml_rel)) {
        return .{ .arch = try std.fmt.allocPrint(arena, "{s}.ml", .{std.fs.path.basename(key)}) };
    }
    return .{ .upstream = ml_rel };
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
            if (std.mem.endsWith(u8, dep_tok, ".cmi") or std.mem.endsWith(u8, dep_tok, ".cmo") or std.mem.endsWith(u8, dep_tok, ".cmx")) {
                try deps.append(arena, try normalizeDepTok(arena, subdir_prefix, dep_tok));
            }
        }

        var lhs_it = std.mem.tokenizeAny(u8, lhs, " \t");
        while (lhs_it.next()) |target_tok| {
            if (std.mem.endsWith(u8, target_tok, ".cmi") or std.mem.endsWith(u8, target_tok, ".cmo") or std.mem.endsWith(u8, target_tok, ".cmx")) {
                const norm_t = try normalizeDepTok(arena, subdir_prefix, target_tok);
                try addDepsToMap(arena, map, norm_t, deps.items);
            }
        }
    }
}

fn addDepsToMap(
    arena: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged([]const []const u8),
    target: []const u8,
    new_deps: []const []const u8,
) !void {
    if (map.get(target)) |existing| {
        var merged: std.ArrayList([]const u8) = .empty;
        try merged.appendSlice(arena, existing);
        for (new_deps) |d| {
            if (!containsStr(existing, d)) try merged.append(arena, d);
        }
        try map.put(arena, target, merged.items);
    } else {
        try map.put(arena, target, new_deps);
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

const StdlibPlan = struct {
    compflags: []const []const u8,
    plan: Manifest.Plan,
    /// module names archived into stdlib.cma, in link order
    cma: []const []const u8,
};

fn computeStdlibPlan(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root: []const u8,
    root_dir: std.Io.Dir,
    basenames: []const []const u8,
) !StdlibPlan {
    // Query COMPFLAGS and ./Compflags for every stdlib unit in a single `make` invocation
    var make_stdin: std.ArrayList(u8) = .empty;
    try make_stdin.appendSlice(arena, "$(info ZCAML:COMPFLAGS=$(COMPFLAGS))\n");
    for (basenames) |base| {
        const mod_name = try stdlibModuleName(arena, base);
        for ([_][]const u8{ "cmi", "cmo", "cmx" }) |ext| {
            try make_stdin.appendSlice(arena, try std.fmt.allocPrint(
                arena,
                "$(info ZCAML:{s}.{s}=$(shell ./Compflags {s}.{s}))\n",
                .{ mod_name, ext, mod_name, ext },
            ));
        }
    }
    for ([_][]const u8{ "cmo", "cmx" }) |ext| {
        try make_stdin.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "$(info ZCAML:std_exit.{s}=$(shell ./Compflags std_exit.{s}))\n",
            .{ ext, ext },
        ));
    }

    const stdlib_vars = try queryMakeRaw(io, gpa, arena, src_root, "stdlib/Makefile", &.{
        "O=o", "A=a", "S=s", "SO=so", "EXE=",
    }, make_stdin.items);

    const stdlib_depend = try root_dir.readFileAlloc(io, "stdlib/.depend", arena, .unlimited);
    var dep_map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    try parseDependUnionInto(arena, stdlib_depend, "", &dep_map);

    var wave_units: std.ArrayList(WaveUnit) = .empty;
    var cmo_units: std.ArrayList(Unit) = .empty;
    var cma: std.ArrayList([]const u8) = .empty;
    var cmi_by_basename: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (basenames) |base| {
        const mod_name = try stdlibModuleName(arena, base);
        const is_stdlib = std.mem.eql(u8, base, "stdlib");
        const is_labels = std.mem.endsWith(u8, base, "Labels");
        const cmi_flags = stdlib_vars.get(try std.fmt.allocPrint(arena, "{s}.cmi", .{mod_name})) orelse &.{};
        const cmo_flags = stdlib_vars.get(try std.fmt.allocPrint(arena, "{s}.cmo", .{mod_name})) orelse &.{};
        const cmx_flags = stdlib_vars.get(try std.fmt.allocPrint(arena, "{s}.cmx", .{mod_name})) orelse &.{};

        const ml_rel = try std.fmt.allocPrint(arena, "stdlib/{s}.ml", .{base});
        const mli_rel = try std.fmt.allocPrint(arena, "stdlib/{s}.mli", .{base});
        const ml_src: Src = if (std.mem.eql(u8, base, "sys"))
            .{ .gen = .stdlib_sys_ml }
        else if (is_stdlib)
            .{ .expanded = ml_rel }
        else
            .{ .upstream = ml_rel };

        try cmi_by_basename.put(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{mod_name}), mod_name);
        if (!is_stdlib and !std.mem.eql(u8, mod_name, "camlinternalFormatBasics")) {
            try addDepsToMap(arena, &dep_map, try std.fmt.allocPrint(arena, "{s}.cmi", .{mod_name}), &.{"stdlib.cmi"});
            try addDepsToMap(arena, &dep_map, try std.fmt.allocPrint(arena, "{s}.cmo", .{mod_name}), &.{"stdlib.cmi"});
            try addDepsToMap(arena, &dep_map, try std.fmt.allocPrint(arena, "{s}.cmx", .{mod_name}), &.{"stdlib.cmx"});
        }

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
    const std_exit_flags = stdlib_vars.get("std_exit.cmo") orelse &.{};
    try cmi_by_basename.put(arena, "std_exit.cmi", "std_exit");
    try addDepsToMap(arena, &dep_map, "std_exit.cmi", &.{"stdlib.cmi"});
    try addDepsToMap(arena, &dep_map, "std_exit.cmx", &.{"stdlib.cmx"});
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
        .native_flags = stdlib_vars.get("std_exit.cmx") orelse &.{},
        .dest = .lib,
    });

    return .{
        .compflags = stdlib_vars.get("COMPFLAGS").?,
        .plan = .{
            .cmi_waves = try sortCmiWaves(arena, wave_units.items, &dep_map, &cmi_by_basename),
            .cmo_units = cmo_units.items,
            .cmx_waves = try nativeWaves(arena, wave_units.items, cmo_units.items, &dep_map, false),
        },
        .cma = cma.items,
    };
}

fn parseOcamlVersion(arena: std.mem.Allocator, version_m4: []const u8, version_file: []const u8) !Manifest.Version {
    const dev_str = extractM4Define(version_m4, "OCAML__DEVELOPMENT_VERSION") orelse @panic("Missing OCAML__DEVELOPMENT_VERSION");
    const major = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__VERSION_MAJOR").?, 10);
    const minor = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__VERSION_MINOR").?, 10);
    const patchlevel = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__VERSION_PATCHLEVEL").?, 10);
    const release_number = try std.fmt.parseInt(u32, extractM4Define(version_m4, "OCAML__RELEASE_NUMBER").?, 10);
    const extra = extractM4Define(version_m4, "OCAML__VERSION_EXTRA") orelse "";
    const extra_prefix = extractM4Define(version_m4, "OCAML__VERSION_EXTRA_PREFIX") orelse "+";
    const version_string = if (extra.len == 0)
        try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ major, minor, patchlevel })
    else
        try std.fmt.allocPrint(arena, "{d}.{d}.{d}{s}{s}", .{ major, minor, patchlevel, extra_prefix, extra });

    const first_line = std.mem.trim(u8, std.mem.sliceTo(version_file, '\n'), " \t\r");
    if (!std.mem.eql(u8, first_line, version_string)) @panic("VERSION mismatch");

    const prefix = extractM4Define(version_m4, "MAGIC_NUMBER__PREFIX").?;
    const ver = extractM4Define(version_m4, "MAGIC_NUMBER__VERSION").?;
    const exec_format = extractM4Define(version_m4, "EXEC__FORMAT").?;

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
        .magic = .{
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
        },
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
