const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const InputDir = utils.InputDir;
const OutputDir = utils.OutputDir;

const Self = @This();

pub const HeaderFormat = enum {
    camlheader_5_0,
    launch_info_5_2,
    launch_info_5_5,
};

ocamlrun: InputFile,
ocamlc: InputFile,
primitives: InputFile,
stdlib_src_dir: InputDir,
compflags_script: InputFile,
depend_file: InputFile,
sys_ml: InputFile,
meta_file: InputFile,
header_exe: ?InputFile = null,
header_format: HeaderFormat = .launch_info_5_5,
is_windows_target: bool = false,
target_bindir: []const u8 = "/usr/local/bin",
compflags: []const []const u8 = &.{},
module_basenames: []const []const u8 = &.{},
out_dir: OutputDir,

pub fn run(self: *Self, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_dir_handle = try self.out_dir.open(io, .{});
    defer out_dir_handle.close(io);

    const out_dir_path = self.out_dir.path();
    const stdlib_src_path = self.stdlib_src_dir.path();

    // 1. Parse stdlib/Compflags strictly
    const compflags_src = try self.compflags_script.readAll(io, gpa);
    defer gpa.free(compflags_src);
    const rules = try parseCompflagsScript(arena, compflags_src);

    // 2. Write rendered sys.ml and META into out_dir
    {
        const sys_ml_bytes = try self.sys_ml.readAll(io, gpa);
        defer gpa.free(sys_ml_bytes);
        try out_dir_handle.writeFile(io, .{ .sub_path = "sys.ml", .data = sys_ml_bytes });
    }
    {
        const meta_bytes = try self.meta_file.readAll(io, gpa);
        defer gpa.free(meta_bytes);
        try out_dir_handle.writeFile(io, .{ .sub_path = "META", .data = meta_bytes });
    }

    // 3. Parse stdlib/.depend
    const depend_src = try self.depend_file.readAll(io, gpa);
    defer gpa.free(depend_src);
    const cmi_deps_map = try parseDependCmiMap(arena, depend_src);
    const has_std_exit_mli = cmi_deps_map.contains("std_exit.cmi");

    // 4. Copy source .mli and .ml files into out_dir for every module + std_exit
    for (self.module_basenames) |basename| {
        const mli_name = try std.fmt.allocPrint(arena, "{s}.mli", .{basename});
        const ml_name = try std.fmt.allocPrint(arena, "{s}.ml", .{basename});
        try copySourceFile(io, gpa, stdlib_src_path, out_dir_handle, mli_name);
        if (!std.mem.eql(u8, basename, "sys")) {
            try copySourceFile(io, gpa, stdlib_src_path, out_dir_handle, ml_name);
        }
    }
    if (has_std_exit_mli) {
        try copySourceFile(io, gpa, stdlib_src_path, out_dir_handle, "std_exit.mli");
    }
    try copySourceFile(io, gpa, stdlib_src_path, out_dir_handle, "std_exit.ml");

    // 5. Compute prefixed module names (matching StdlibModules PREFIX_MODULE rule)
    var mod_names: std.ArrayList([]const u8) = .empty;
    for (self.module_basenames) |basename| {
        const mod_name = try prefixStdlibModule(arena, basename);
        try mod_names.append(arena, mod_name);
    }

    // 6. Compile all .cmi files in topological wave order
    try self.compileAllInterfacesTopological(
        io,
        gpa,
        arena,
        out_dir_handle,
        out_dir_path,
        rules,
        mod_names.items,
        &cmi_deps_map,
        has_std_exit_mli,
    );

    // 6. Compile all .cmo files in parallel batches (since all .cmi dependencies are now ready)
    const total_mods = self.module_basenames.len + 1; // +1 for std_exit
    var cmo_cmds: std.ArrayList([]const []const u8) = .empty;
    var temp_pp_files: std.ArrayList([]const u8) = .empty;

    for (self.module_basenames, mod_names.items) |basename, mod_name| {
        const prep = try self.prepareImplementationCmd(
            io,
            gpa,
            arena,
            out_dir_handle,
            out_dir_path,
            rules,
            basename,
            mod_name,
        );
        try cmo_cmds.append(arena, prep.argv);
        if (prep.temp_sub_path) |tmp| try temp_pp_files.append(arena, tmp);
    }
    {
        const prep = try self.prepareImplementationCmd(
            io,
            gpa,
            arena,
            out_dir_handle,
            out_dir_path,
            rules,
            "std_exit",
            "std_exit",
        );
        try cmo_cmds.append(arena, prep.argv);
        if (prep.temp_sub_path) |tmp| try temp_pp_files.append(arena, tmp);
    }
    std.debug.assert(cmo_cmds.items.len == total_mods);

    try runCommandsInParallelBatches(io, gpa, cmo_cmds.items, 16);

    for (temp_pp_files.items) |rel_name| {
        try copySourceFile(io, gpa, stdlib_src_path, out_dir_handle, rel_name);
    }

    // 7. Link stdlib.cma in exact STDLIB_MODULES order
    {
        var link_argv: std.ArrayList([]const u8) = .empty;
        try link_argv.appendSlice(arena, &.{
            self.ocamlrun.path(),
            self.ocamlc.path(),
            "-use-prims",
            self.primitives.path(),
            "-nostdlib",
            "-I",
            out_dir_path,
            "-a",
            "-o",
            try std.fmt.allocPrint(arena, "{s}/stdlib.cma", .{out_dir_path}),
        });
        for (mod_names.items) |mod_name| {
            try link_argv.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}.cmo", .{ out_dir_path, mod_name }));
        }
        try runChecked(io, gpa, link_argv.items);
    }

    // 8. Generate bytecode launcher header(s)
    try self.writeLauncherHeaders(io, gpa, arena, out_dir_handle);
}

fn copySourceFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    src_dir_path: []const u8,
    out_dir_handle: std.Io.Dir,
    file_name: []const u8,
) !void {
    const full_src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ src_dir_path, file_name });
    defer gpa.free(full_src);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, full_src, gpa, .unlimited);
    defer gpa.free(data);
    try out_dir_handle.writeFile(io, .{ .sub_path = file_name, .data = data });
}

fn prefixStdlibModule(arena: std.mem.Allocator, basename: []const u8) ![]const u8 {
    if (std.mem.eql(u8, basename, "stdlib") or std.mem.startsWith(u8, basename, "camlinternal")) {
        return basename;
    }
    var cap = try arena.dupe(u8, basename);
    cap[0] = std.ascii.toUpper(cap[0]);
    return std.fmt.allocPrint(arena, "stdlib__{s}", .{cap});
}

const PreparedCmd = struct {
    argv: []const []const u8,
    temp_sub_path: ?[]const u8,
};

fn parseDependCmiMap(
    arena: std.mem.Allocator,
    depend_src: []const u8,
) !std.StringHashMapUnmanaged([]const []const u8) {
    var map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var joined_line: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, depend_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

        if (std.mem.endsWith(u8, trimmed, "\\")) {
            try joined_line.appendSlice(arena, trimmed[0 .. trimmed.len - 1]);
            try joined_line.append(arena, ' ');
            continue;
        }

        try joined_line.appendSlice(arena, trimmed);
        const full = std.mem.trim(u8, joined_line.items, " \t");
        joined_line = .empty;

        const colon_idx = std.mem.indexOfScalar(u8, full, ':') orelse {
            std.debug.panic("stdlib/.depend safety check failed: missing ':' in '{s}'", .{full});
        };
        const lhs = std.mem.trim(u8, full[0..colon_idx], " \t");
        const rhs = std.mem.trim(u8, full[colon_idx + 1 ..], " \t");

        var cmi_deps: std.ArrayList([]const u8) = .empty;
        var rhs_it = std.mem.tokenizeAny(u8, rhs, " \t");
        while (rhs_it.next()) |dep_tok| {
            if (std.mem.endsWith(u8, dep_tok, ".cmi")) {
                try cmi_deps.append(arena, dep_tok);
            }
        }

        var lhs_it = std.mem.tokenizeAny(u8, lhs, " \t");
        while (lhs_it.next()) |target_tok| {
            if (std.mem.endsWith(u8, target_tok, ".cmi")) {
                try map.put(arena, target_tok, cmi_deps.items);
            }
        }
    }

    if (joined_line.items.len != 0) {
        std.debug.panic("stdlib/.depend safety check failed: trailing backslash at EOF", .{});
    }

    return map;
}

fn compileAllInterfacesTopological(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    rules: []const CompflagRule,
    mod_names: []const []const u8,
    cmi_deps_map: *const std.StringHashMapUnmanaged([]const []const u8),
    has_std_exit_mli: bool,
) !void {
    const total = self.module_basenames.len + @as(usize, if (has_std_exit_mli) 1 else 0);
    var all_basenames = try arena.alloc([]const u8, total);
    var all_mod_names = try arena.alloc([]const u8, total);
    var all_cmi_names = try arena.alloc([]const u8, total);

    for (self.module_basenames, mod_names, 0..) |b_name, m_name, i| {
        all_basenames[i] = b_name;
        all_mod_names[i] = m_name;
        all_cmi_names[i] = try std.fmt.allocPrint(arena, "{s}.cmi", .{m_name});
    }
    if (has_std_exit_mli) {
        all_basenames[total - 1] = "std_exit";
        all_mod_names[total - 1] = "std_exit";
        all_cmi_names[total - 1] = "std_exit.cmi";
    }

    var built_set: std.StringHashMapUnmanaged(void) = .empty;
    var done = try arena.alloc(bool, total);
    @memset(done, false);

    var completed: usize = 0;
    while (completed < total) {
        var wave_cmds: std.ArrayList([]const []const u8) = .empty;
        var wave_temps: std.ArrayList([]const u8) = .empty;
        var wave_indices: std.ArrayList(usize) = .empty;

        for (0..total) |i| {
            if (done[i]) continue;
            const cmi_name = all_cmi_names[i];

            // Implicit dependencies from stdlib/Makefile:
            // - stdlib.cmi depends on camlinternalFormatBasics.cmi
            // - all other modules depend on stdlib.cmi
            if (std.mem.eql(u8, cmi_name, "stdlib.cmi")) {
                if (!built_set.contains("camlinternalFormatBasics.cmi")) continue;
            } else if (!std.mem.eql(u8, cmi_name, "camlinternalFormatBasics.cmi")) {
                if (!built_set.contains("stdlib.cmi")) continue;
            }

            // Explicit dependencies from stdlib/.depend
            const deps = cmi_deps_map.get(cmi_name) orelse {
                std.debug.panic("stdlib/.depend safety check failed: target '{s}' not found in stdlib/.depend", .{cmi_name});
            };
            var all_deps_ready = true;
            for (deps) |dep_cmi| {
                if (!built_set.contains(dep_cmi)) {
                    all_deps_ready = false;
                    break;
                }
            }
            if (!all_deps_ready) continue;

            const prep = try self.prepareInterfaceCmd(
                io,
                gpa,
                arena,
                out_dir_handle,
                out_dir_path,
                rules,
                all_basenames[i],
                all_mod_names[i],
            );
            try wave_cmds.append(arena, prep.argv);
            if (prep.temp_sub_path) |tmp| try wave_temps.append(arena, tmp);
            try wave_indices.append(arena, i);
        }

        if (wave_indices.items.len == 0) {
            std.debug.panic("stdlib/.depend safety check failed: dependency cycle or unresolved .cmi dependency", .{});
        }

        try runCommandsInParallelBatches(io, gpa, wave_cmds.items, 16);

        for (wave_temps.items) |rel_name| {
            try copySourceFile(io, gpa, self.stdlib_src_dir.path(), out_dir_handle, rel_name);
        }

        for (wave_indices.items) |idx| {
            done[idx] = true;
            try built_set.put(arena, all_cmi_names[idx], {});
            completed += 1;
        }
    }
}

fn prepareInterfaceCmd(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    rules: []const CompflagRule,
    basename: []const u8,
    mod_name: []const u8,
) !PreparedCmd {
    const target_cmi = try std.fmt.allocPrint(arena, "{s}.cmi", .{mod_name});
    const matched = matchCompflags(rules, target_cmi);

    const mli_rel = try std.fmt.allocPrint(arena, "{s}.mli", .{basename});
    const input_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, mli_rel });
    var temp_sub_path: ?[]const u8 = null;

    if (matched.expand_aliases) {
        const raw = try out_dir_handle.readFileAlloc(io, mli_rel, gpa, .unlimited);
        defer gpa.free(raw);
        const expanded = try expandModuleAliases(arena, mli_rel, raw);
        try out_dir_handle.writeFile(io, .{ .sub_path = mli_rel, .data = expanded });
        temp_sub_path = mli_rel;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        self.ocamlrun.path(),
        self.ocamlc.path(),
        "-use-prims",
        self.primitives.path(),
    });
    try argv.appendSlice(arena, self.compflags);
    try argv.appendSlice(arena, matched.flags);
    try argv.appendSlice(arena, &.{
        "-I",
        out_dir_path,
        "-o",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, target_cmi }),
        "-c",
        input_path,
    });

    return .{
        .argv = argv.items,
        .temp_sub_path = temp_sub_path,
    };
}

fn prepareImplementationCmd(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    rules: []const CompflagRule,
    basename: []const u8,
    mod_name: []const u8,
) !PreparedCmd {
    const target_cmo = try std.fmt.allocPrint(arena, "{s}.cmo", .{mod_name});
    const matched = matchCompflags(rules, target_cmo);

    const ml_rel = try std.fmt.allocPrint(arena, "{s}.ml", .{basename});
    const input_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, ml_rel });
    var temp_sub_path: ?[]const u8 = null;

    if (matched.expand_aliases) {
        const raw = try out_dir_handle.readFileAlloc(io, ml_rel, gpa, .unlimited);
        defer gpa.free(raw);
        const expanded = try expandModuleAliases(arena, ml_rel, raw);
        try out_dir_handle.writeFile(io, .{ .sub_path = ml_rel, .data = expanded });
        temp_sub_path = ml_rel;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        self.ocamlrun.path(),
        self.ocamlc.path(),
        "-use-prims",
        self.primitives.path(),
    });
    try argv.appendSlice(arena, self.compflags);
    try argv.appendSlice(arena, matched.flags);
    try argv.appendSlice(arena, &.{
        "-I",
        out_dir_path,
        "-o",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, target_cmo }),
        "-c",
        input_path,
    });

    return .{
        .argv = argv.items,
        .temp_sub_path = temp_sub_path,
    };
}

fn writeLauncherHeaders(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_handle: std.Io.Dir,
) !void {
    const header_exe_bytes: []const u8 = if (self.header_exe) |hexe|
        try hexe.readAll(io, gpa)
    else
        &.{};
    defer if (self.header_exe != null) gpa.free(header_exe_bytes);

    switch (self.header_format) {
        .launch_info_5_5 => {
            var buf: std.ArrayList(u8) = .empty;
            try buf.append(arena, 0);
            try buf.appendSlice(arena, header_exe_bytes);
            try out_dir_handle.writeFile(io, .{
                .sub_path = "runtime-launch-info",
                .data = buf.items,
            });
        },
        .launch_info_5_2 => {
            const launch_method = if (self.is_windows_target) "exe" else "sh";
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, launch_method);
            try buf.append(arena, '\n');
            try buf.appendSlice(arena, self.target_bindir);
            try buf.append(arena, 0);
            try buf.append(arena, '\n');
            try buf.appendSlice(arena, header_exe_bytes);
            try out_dir_handle.writeFile(io, .{
                .sub_path = "runtime-launch-info",
                .data = buf.items,
            });
        },
        .camlheader_5_0 => {
            if (self.is_windows_target) {
                try out_dir_handle.writeFile(io, .{ .sub_path = "camlheader", .data = header_exe_bytes });
                try out_dir_handle.writeFile(io, .{ .sub_path = "camlheader_ur", .data = header_exe_bytes });
                try out_dir_handle.writeFile(io, .{ .sub_path = "camlheaderd", .data = header_exe_bytes });
                try out_dir_handle.writeFile(io, .{ .sub_path = "camlheaderi", .data = header_exe_bytes });
            } else {
                try out_dir_handle.writeFile(io, .{
                    .sub_path = "camlheader_ur",
                    .data = "#!",
                });
                try out_dir_handle.writeFile(io, .{
                    .sub_path = "camlheader",
                    .data = try std.fmt.allocPrint(arena, "#!{s}/ocamlrun\n", .{self.target_bindir}),
                });
                try out_dir_handle.writeFile(io, .{
                    .sub_path = "camlheaderd",
                    .data = try std.fmt.allocPrint(arena, "#!{s}/ocamlrund\n", .{self.target_bindir}),
                });
                try out_dir_handle.writeFile(io, .{
                    .sub_path = "camlheaderi",
                    .data = try std.fmt.allocPrint(arena, "#!{s}/ocamlruni\n", .{self.target_bindir}),
                });
            }
        },
    }
}

/// Pure-Zig implementation of `stdlib/expand_module_aliases.awk`.
pub fn expandModuleAliases(
    arena: std.mem.Allocator,
    filename: []const u8,
    src: []const u8,
) ![]const u8 {
    const is_labels = std.mem.indexOf(u8, filename, "Labels") != null;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "# 1 \"{s}\"\n", .{filename}));

    var state: u8 = 0;
    const trimmed_src = if (src.len > 0 and src[src.len - 1] == '\n')
        src[0 .. src.len - 1]
    else
        src;
    var lines = std.mem.splitScalar(u8, trimmed_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (std.mem.indexOf(u8, line, "(*MODULE_ALIASES*)") != null) {
            state = 1;
        }

        if (state == 0) {
            if (is_labels) {
                const transformed = try transformLabelsSinceLine(arena, line);
                try out.appendSlice(arena, transformed);
            } else {
                try out.appendSlice(arena, line);
            }
            try out.append(arena, '\n');
        } else if (state == 1) {
            state = 2;
        } else {
            var tok_it = std.mem.tokenizeAny(u8, line, " \t");
            const tok1 = tok_it.next() orelse "";
            if (std.mem.eql(u8, tok1, "module")) {
                const mod_name = tok_it.next() orelse @panic("Malformed module alias in stdlib");
                const eq_tok = tok_it.next() orelse @panic("Malformed module alias '=' in stdlib");
                if (!std.mem.eql(u8, eq_tok, "=")) @panic("Expected '=' in stdlib module alias");
                const target_name = tok_it.next() orelse @panic("Malformed module alias target in stdlib");
                try out.appendSlice(arena, try std.fmt.allocPrint(
                    arena,
                    "\n(** @canonical Stdlib.{s} *)\nmodule {s} = Stdlib__{s}\n",
                    .{ mod_name, mod_name, target_name },
                ));
            } else {
                try out.appendSlice(arena, line);
                try out.append(arena, '\n');
            }
        }
    }

    return out.items;
}

/// Implements:
/// `if (FILENAME ~ /Labels/ && sub(/@since [^(]* \(/, "@since ")) sub(/ in [^)]*\)/, "");`
fn transformLabelsSinceLine(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    const since_idx = std.mem.indexOf(u8, line, "@since ") orelse return line;
    const after_since = line[since_idx + "@since ".len ..];
    const open_paren_rel = std.mem.indexOfScalar(u8, after_since, '(') orelse return line;
    if (open_paren_rel == 0 or after_since[open_paren_rel - 1] != ' ') return line;

    const after_open = after_since[open_paren_rel + 1 ..];
    const in_rel = std.mem.indexOf(u8, after_open, " in ") orelse return line;
    const close_paren_rel = std.mem.indexOfScalarPos(u8, after_open, in_rel + 4, ')') orelse return line;

    var res: std.ArrayList(u8) = .empty;
    try res.appendSlice(arena, line[0 .. since_idx + "@since ".len]);
    try res.appendSlice(arena, after_open[0..in_rel]);
    try res.appendSlice(arena, after_open[close_paren_rel + 1 ..]);
    return res.items;
}

pub const CompflagRule = struct {
    patterns: []const []const u8,
    flags: []const []const u8,
    expand_aliases: bool,
};

pub fn parseCompflagsScript(arena: std.mem.Allocator, src: []const u8) ![]const CompflagRule {
    var rules: std.ArrayList(CompflagRule) = .empty;

    var in_case = false;
    var found_esac = false;
    var joined_line: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;

        if (!in_case) {
            if (std.mem.eql(u8, line, "case $1 in")) {
                in_case = true;
            }
            continue;
        }

        if (std.mem.eql(u8, line, "esac")) {
            found_esac = true;
            break;
        }

        if (std.mem.endsWith(u8, line, "\\")) {
            try joined_line.appendSlice(arena, line[0 .. line.len - 1]);
            try joined_line.append(arena, ' ');
            continue;
        }

        if (!std.mem.endsWith(u8, line, ";;")) {
            try joined_line.appendSlice(arena, line);
            try joined_line.append(arena, ' ');
            continue;
        }

        try joined_line.appendSlice(arena, line);
        const stmt = std.mem.trim(u8, joined_line.items, " \t");
        joined_line = .empty;

        const close_paren = std.mem.indexOfScalar(u8, stmt, ')') orelse {
            std.debug.panic("Compflags safety check failed: missing ')' in case arm: '{s}'", .{stmt});
        };
        if (!std.mem.endsWith(u8, stmt, ";;")) {
            std.debug.panic("Compflags safety check failed: missing ';;' in case arm: '{s}'", .{stmt});
        }

        const pat_str = std.mem.trim(u8, stmt[0..close_paren], " \t");
        const body_str = std.mem.trim(u8, stmt[close_paren + 1 .. stmt.len - 2], " \t");
        if (!std.mem.startsWith(u8, body_str, "echo ")) {
            std.debug.panic("Compflags safety check failed: expected 'echo ...' in case arm: '{s}'", .{body_str});
        }

        var patterns: std.ArrayList([]const u8) = .empty;
        var pat_it = std.mem.splitScalar(u8, pat_str, '|');
        while (pat_it.next()) |p| {
            try patterns.append(arena, std.mem.trim(u8, p, " \t"));
        }

        var flags: std.ArrayList([]const u8) = .empty;
        var expand_aliases = false;

        const echo_rest = body_str["echo ".len..];
        var i: usize = 0;
        while (i < echo_rest.len) {
            if (echo_rest[i] == ' ' or echo_rest[i] == '\t') {
                i += 1;
                continue;
            }
            if (echo_rest[i] != '\'') {
                std.debug.panic("Compflags safety check failed: unexpected unquoted token in '{s}'", .{body_str});
            }
            const end_quote = std.mem.indexOfScalarPos(u8, echo_rest, i + 1, '\'') orelse {
                std.debug.panic("Compflags safety check failed: unterminated quote in '{s}'", .{body_str});
            };
            const quoted = std.mem.trim(u8, echo_rest[i + 1 .. end_quote], " \t");
            if (std.mem.eql(u8, quoted, "-pp \"$AWK -f ./expand_module_aliases.awk\"")) {
                expand_aliases = true;
            } else if (std.mem.indexOfAny(u8, quoted, "$\"") != null) {
                std.debug.panic("Compflags safety check failed: unexpected shell expression '{s}'", .{quoted});
            } else {
                var tok_it = std.mem.tokenizeAny(u8, quoted, " \t");
                while (tok_it.next()) |flag_tok| {
                    try flags.append(arena, flag_tok);
                }
            }
            i = end_quote + 1;
        }

        try rules.append(arena, .{
            .patterns = patterns.items,
            .flags = flags.items,
            .expand_aliases = expand_aliases,
        });
    }

    if (!in_case or !found_esac or rules.items.len == 0 or joined_line.items.len != 0) {
        std.debug.panic("Compflags safety check failed: could not parse case statement in stdlib/Compflags", .{});
    }

    return rules.items;
}

fn matchCompflags(rules: []const CompflagRule, target: []const u8) CompflagRule {
    for (rules) |rule| {
        for (rule.patterns) |pat| {
            if (globMatch(pat, target)) return rule;
        }
    }
    std.debug.panic("Compflags safety check failed: no rule matched '{s}'", .{target});
}

fn globMatch(pat: []const u8, str: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;

    while (s < str.len) {
        if (p < pat.len and pat[p] == '*') {
            star_p = p;
            star_s = s;
            p += 1;
        } else if (p < pat.len and pat[p] == '[') {
            const close_bracket = std.mem.indexOfScalarPos(u8, pat, p + 1, ']') orelse {
                std.debug.panic("Malformed '[' in Compflags pattern '{s}'", .{pat});
            };
            const chars = pat[p + 1 .. close_bracket];
            if (std.mem.indexOfScalar(u8, chars, str[s]) != null) {
                p = close_bracket + 1;
                s += 1;
            } else if (star_p) |sp| {
                p = sp + 1;
                star_s += 1;
                s = star_s;
            } else {
                return false;
            }
        } else if (p < pat.len and (pat[p] == '?' or pat[p] == '{')) {
            std.debug.panic("Unsupported glob metacharacter in Compflags pattern '{s}'", .{pat});
        } else if (p < pat.len and pat[p] == str[s]) {
            p += 1;
            s += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_s += 1;
            s = star_s;
        } else {
            return false;
        }
    }

    while (p < pat.len and pat[p] == '*') : (p += 1) {}
    return p == pat.len;
}

fn runChecked(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !void {
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }

    const joined = try std.mem.join(gpa, " ", argv);
    defer gpa.free(joined);
    std.log.err("Command failed: {s}", .{joined});
    if (res.stdout.len > 0) std.log.err("stdout:\n{s}", .{res.stdout});
    if (res.stderr.len > 0) std.log.err("stderr:\n{s}", .{res.stderr});
    return error.SubprocessFailed;
}

fn runCommandsInParallelBatches(
    io: std.Io,
    gpa: std.mem.Allocator,
    cmds: []const []const []const u8,
    batch_size: usize,
) !void {
    var idx: usize = 0;
    while (idx < cmds.len) {
        const end = @min(idx + batch_size, cmds.len);
        const slice = cmds[idx..end];

        var children = try gpa.alloc(std.process.Child, slice.len);
        defer gpa.free(children);

        for (slice, 0..) |argv, i| {
            children[i] = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .ignore,
                .stdout = .inherit,
                .stderr = .inherit,
            });
        }

        var failed = false;
        for (slice, 0..) |argv, i| {
            const term = try children[i].wait(io);
            switch (term) {
                .exited => |code| if (code != 0) {
                    const joined = try std.mem.join(gpa, " ", argv);
                    defer gpa.free(joined);
                    std.log.err("Command exited with code {d}: {s}", .{ code, joined });
                    failed = true;
                },
                else => {
                    const joined = try std.mem.join(gpa, " ", argv);
                    defer gpa.free(joined);
                    std.log.err("Command terminated abnormally: {s}", .{joined});
                    failed = true;
                },
            }
        }

        if (failed) return error.SubprocessFailed;
        idx = end;
    }
}
