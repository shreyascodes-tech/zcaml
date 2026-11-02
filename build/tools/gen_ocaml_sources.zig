const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const InputDir = utils.InputDir;
const OutputFile = utils.OutputFile;
const OutputDir = utils.OutputDir;

pub const GenStdlibSources = struct {
    ocaml_src_dir: InputDir,
    expanded_dir: OutputDir,

    /// Written to `expanded_dir/<same relative path>` (see `Manifest.Src.expanded`).
    const files_to_expand = [_][]const u8{
        "stdlib/stdlib.mli",
        "stdlib/stdlib.ml",
        "stdlib/arrayLabels.mli",
        "stdlib/listLabels.mli",
        "stdlib/bytesLabels.mli",
        "stdlib/stringLabels.mli",
        "stdlib/moreLabels.mli",
        "stdlib/stdLabels.mli",
        "otherlibs/unix/unixLabels.mli",
    };

    pub fn run(self: *GenStdlibSources, init: std.process.Init) !void {
        const io = init.io;
        const gpa = init.gpa;
        const arena = init.arena.allocator();

        const src_root = self.ocaml_src_dir.path();
        var root_dir = try std.Io.Dir.cwd().openDir(io, src_root, .{});
        defer root_dir.close(io);

        var exp_dir = try self.expanded_dir.open(io, .{});
        defer exp_dir.close(io);

        for (files_to_expand) |rel| {
            const raw = try root_dir.readFileAlloc(io, rel, gpa, .unlimited);
            defer gpa.free(raw);
            const expanded = try expandModuleAliases(arena, std.fs.path.basename(rel), raw);
            if (std.fs.path.dirname(rel)) |dir| try exp_dir.createDirPath(io, dir);
            try exp_dir.writeFile(io, .{ .sub_path = rel, .data = expanded });
        }
    }
};

pub const GenLaunchInfo = struct {
    header_exe: InputFile,
    runtime_launch_info: OutputFile,

    pub fn run(self: *GenLaunchInfo, init: std.process.Init) !void {
        const io = init.io;
        const gpa = init.gpa;
        const arena = init.arena.allocator();

        const exe_bytes = try self.header_exe.readAll(io, gpa);
        defer gpa.free(exe_bytes);

        var launch_buf: std.ArrayList(u8) = .empty;
        try launch_buf.append(arena, 0);
        try launch_buf.appendSlice(arena, exe_bytes);
        try writeOutputFile(io, self.runtime_launch_info, launch_buf.items);
    }
};

pub const GenCompilerSources = struct {
    ocaml_src_dir: InputDir,
    primitives: InputFile,
    arch64: bool = true,
    domainstate_ml: OutputFile,
    domainstate_mli: OutputFile,
    runtimedef_ml: OutputFile,
    menhir_lib_mli: OutputFile,
    parser_ml: OutputFile,
    parser_mli: OutputFile,

    pub fn run(self: *GenCompilerSources, init: std.process.Init) !void {
        const io = init.io;
        const gpa = init.gpa;
        const arena = init.arena.allocator();

        const src_root = self.ocaml_src_dir.path();
        var root_dir = try std.Io.Dir.cwd().openDir(io, src_root, .{});
        defer root_dir.close(io);

        try self.generateDomainstate(io, gpa, arena, root_dir);
        try self.generateRuntimedef(io, gpa, arena, root_dir);
        try self.generateMenhir(io, gpa, arena, root_dir);
    }

    fn generateDomainstate(
        self: *GenCompilerSources,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        root_dir: std.Io.Dir,
    ) !void {
        const tbl_src = try root_dir.readFileAlloc(io, "runtime/caml/domain_state.tbl", gpa, .unlimited);
        defer gpa.free(tbl_src);

        const cfg_h_src = try root_dir.readFileAlloc(io, "runtime/caml/config.h", gpa, .unlimited);
        defer gpa.free(cfg_h_src);

        if (std.mem.indexOf(u8, cfg_h_src, "#define Stack_ctx_words (6 + 1)") == null or
            std.mem.indexOf(u8, cfg_h_src, "#define Stack_ctx_words (6 + 2)") == null)
        {
            @panic("domainstate safety check failed: unexpected Stack_ctx_words in runtime/caml/config.h");
        }

        var fields: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, tbl_src, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "DOMAIN_STATE(")) {
                const inner = line["DOMAIN_STATE(".len..];
                const comma_idx = std.mem.indexOfScalar(u8, inner, ',') orelse @panic("Malformed DOMAIN_STATE");
                const close_idx = std.mem.indexOfScalarPos(u8, inner, comma_idx + 1, ')') orelse @panic("Malformed DOMAIN_STATE");
                const field_name = std.mem.trim(u8, inner[comma_idx + 1 .. close_idx], " \t");
                try fields.append(arena, field_name);
            }
        }
        if (fields.items.len == 0) @panic("0 DOMAIN_STATE entries found");

        const stack_ctx_expr = if (self.arch64) "(6 + 1)" else "(6 + 2)";

        var ml_out: std.ArrayList(u8) = .empty;
        try ml_out.appendSlice(arena, try std.fmt.allocPrint(arena, "let stack_ctx_words = {s}\n\ntype t =\n", .{stack_ctx_expr}));
        for (fields.items) |f| {
            try ml_out.appendSlice(arena, try std.fmt.allocPrint(arena, "  | Domain_{s}\n", .{f}));
        }
        try ml_out.appendSlice(arena, "\nlet idx_of_field =\n  let curr = 0 in\n");
        for (fields.items) |f| {
            try ml_out.appendSlice(arena, try std.fmt.allocPrint(arena, "  let idx__{s} = curr in\n  let curr = curr + 1 in\n", .{f}));
        }
        try ml_out.appendSlice(arena, "  let _ = curr in\n  function\n");
        for (fields.items) |f| {
            try ml_out.appendSlice(arena, try std.fmt.allocPrint(arena, "  | Domain_{s} -> idx__{s}\n", .{ f, f }));
        }

        var mli_out: std.ArrayList(u8) = .empty;
        try mli_out.appendSlice(arena, "val stack_ctx_words : int\n\ntype t =\n");
        for (fields.items) |f| {
            try mli_out.appendSlice(arena, try std.fmt.allocPrint(arena, "  | Domain_{s}\n", .{f}));
        }
        try mli_out.appendSlice(arena, "\nval idx_of_field : t -> int\n");

        try writeOutputFile(io, self.domainstate_ml, ml_out.items);
        try writeOutputFile(io, self.domainstate_mli, mli_out.items);
    }

    fn generateRuntimedef(
        self: *GenCompilerSources,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        root_dir: std.Io.Dir,
    ) !void {
        const fail_h_src = try root_dir.readFileAlloc(io, "runtime/caml/fail.h", gpa, .unlimited);
        defer gpa.free(fail_h_src);

        const prims_src = try self.primitives.readAll(io, gpa);
        defer gpa.free(prims_src);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "let builtin_exceptions = [|\n");

        var exn_count: usize = 0;
        var fail_lines = std.mem.splitScalar(u8, fail_h_src, '\n');
        while (fail_lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.endsWith(u8, line, "\" */")) {
                if (std.mem.lastIndexOf(u8, line, "/* \"")) |comment_idx| {
                    const quoted = line[comment_idx + 3 .. line.len - 3];
                    const inner = quoted[1 .. quoted.len - 1];
                    var valid = inner.len > 0;
                    for (inner) |c| {
                        if (!std.ascii.isAlphabetic(c) and c != '_') {
                            valid = false;
                            break;
                        }
                    }
                    if (valid) {
                        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "  {s};\n", .{quoted}));
                        exn_count += 1;
                    }
                }
            }
        }
        if (exn_count == 0) @panic("0 builtin_exceptions found in runtime/caml/fail.h");

        try out.appendSlice(arena, "|]\nlet builtin_primitives = [|\n");
        var prim_lines = std.mem.splitScalar(u8, prims_src, '\n');
        while (prim_lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            try out.appendSlice(arena, try std.fmt.allocPrint(arena, "  \"{s}\";\n", .{line}));
        }
        try out.appendSlice(arena, "|]\n");

        try writeOutputFile(io, self.runtimedef_ml, out.items);
    }

    fn generateMenhir(
        self: *GenCompilerSources,
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        root_dir: std.Io.Dir,
    ) !void {
        {
            const mli_raw = try root_dir.readFileAlloc(io, "boot/menhir/menhirLib.mli", gpa, .unlimited);
            defer gpa.free(mli_raw);
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, "[@@@ocaml.warning \"-67\"]\n");
            try buf.appendSlice(arena, mli_raw);
            try writeOutputFile(io, self.menhir_lib_mli, buf.items);
        }
        {
            const ml_raw = try root_dir.readFileAlloc(io, "boot/menhir/parser.ml", gpa, .unlimited);
            defer gpa.free(ml_raw);
            const replaced = try std.mem.replaceOwned(u8, gpa, ml_raw, "MenhirLib", "CamlinternalMenhirLib");
            defer gpa.free(replaced);
            try writeOutputFile(io, self.parser_ml, replaced);
        }
        {
            const mli_raw = try root_dir.readFileAlloc(io, "boot/menhir/parser.mli", gpa, .unlimited);
            defer gpa.free(mli_raw);
            const replaced = try std.mem.replaceOwned(u8, gpa, mli_raw, "MenhirLib", "CamlinternalMenhirLib");
            defer gpa.free(replaced);
            try writeOutputFile(io, self.parser_mli, replaced);
        }
    }
};

pub const PrependEmitLine = struct {
    cvt_emit_output: InputFile,
    arch: []const u8,
    out_emit_ml: OutputFile,

    pub fn run(self: *PrependEmitLine, init: std.process.Init) !void {
        const io = init.io;
        const gpa = init.gpa;
        const arena = init.arena.allocator();

        const body = try self.cvt_emit_output.readAll(io, gpa);
        defer gpa.free(body);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "# 1 \"asmcomp/{s}/emit.mlp\"\n", .{self.arch}));
        try out.appendSlice(arena, body);

        try writeOutputFile(io, self.out_emit_ml, out.items);
    }
};

fn writeOutputFile(io: std.Io, out_file: OutputFile, data: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var fw = try out_file.writer(io, &write_buf);
    defer fw.file.close(io);
    try fw.interface.writeAll(data);
    try fw.flush();
}

pub fn expandModuleAliases(
    arena: std.mem.Allocator,
    filename: []const u8,
    src: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "# 1 \"{s}\"\n", .{filename}));

    const is_labels = std.mem.endsWith(u8, filename, "Labels.mli");
    var in_aliases = false;

    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        if (!first) {
            try out.append(arena, '\n');
        }
        first = false;

        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "(*MODULE_ALIASES*)")) {
            in_aliases = true;
            try out.appendSlice(arena, line);
            continue;
        }

        if (is_labels) {
            if (try rewriteLabelsSinceLine(arena, line)) |rewritten| {
                try out.appendSlice(arena, rewritten);
                continue;
            }
        }

        if (in_aliases) {
            if (try rewriteModuleAliasLine(arena, line)) |rewritten| {
                try out.appendSlice(arena, rewritten);
                continue;
            }
        }

        try out.appendSlice(arena, line);
    }

    return out.items;
}

fn rewriteLabelsSinceLine(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const since_idx = std.mem.indexOf(u8, line, "@since ") orelse return null;
    const after_since = line[since_idx + "@since ".len ..];
    const in_idx = std.mem.indexOf(u8, after_since, " in ") orelse return null;
    const open_paren_rel = std.mem.lastIndexOfScalar(u8, after_since[0..in_idx], '(') orelse return null;
    if (open_paren_rel == 0 or after_since[open_paren_rel - 1] != ' ') return null;
    const close_paren_rel = std.mem.indexOfScalarPos(u8, after_since, in_idx + 4, ')') orelse return null;

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, line[0 .. since_idx + "@since ".len + open_paren_rel - 1]);
    try buf.appendSlice(arena, after_since[close_paren_rel + 1 ..]);
    return buf.items;
}

fn rewriteModuleAliasLine(arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const tok1 = it.next() orelse return null;
    if (!std.mem.eql(u8, tok1, "module")) return null;
    const mod_name = it.next() orelse return null;
    const eq_tok = it.next() orelse return null;
    if (!std.mem.eql(u8, eq_tok, "=")) return null;
    const target_mod = it.next() orelse return null;

    return try std.fmt.allocPrint(
        arena,
        "\n(** @canonical Stdlib.{s} *)\nmodule {s} = Stdlib__{s}",
        .{ mod_name, mod_name, target_mod },
    );
}
