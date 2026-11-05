//! Generated compiler sources: `Domainstate`, `Runtimedef`, the
//! `CamlinternalMenhirLib`-renamed boot parser, and the patched `Ccomp`.
const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const InputDir = utils.InputDir;
const OutputFile = utils.OutputFile;
const replaceOnce = utils.replaceOnce;

const GenCompilerSources = @This();

ocaml_src_dir: InputDir,
primitives: InputFile,
ccomp_zig_cache_ml: InputFile,
domainstate_ml: OutputFile,
domainstate_mli: OutputFile,
runtimedef_ml: OutputFile,
menhir_lib_mli: OutputFile,
parser_ml: OutputFile,
parser_mli: OutputFile,
ccomp_ml: OutputFile,

pub fn run(self: *GenCompilerSources, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var root_dir = try self.ocaml_src_dir.open(io, .{});
    defer root_dir.close(io);

    try self.generateDomainstate(io, gpa, arena, root_dir);
    try self.generateRuntimedef(io, gpa, arena, root_dir);
    try self.generateMenhir(io, gpa, arena, root_dir);
    try self.generateCcomp(io, arena, root_dir);
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

    // Every supported target is 64-bit (`Stack_ctx_words` is `6 + 2` on 32-bit ones).
    var ml_out: std.ArrayList(u8) = .empty;
    try ml_out.appendSlice(arena, "let stack_ctx_words = (6 + 1)\n\ntype t =\n");
    for (fields.items) |f| {
        try ml_out.print(arena, "  | Domain_{s}\n", .{f});
    }
    try ml_out.appendSlice(arena, "\nlet idx_of_field =\n  let curr = 0 in\n");
    for (fields.items) |f| {
        try ml_out.print(arena, "  let idx__{s} = curr in\n  let curr = curr + 1 in\n", .{f});
    }
    try ml_out.appendSlice(arena, "  let _ = curr in\n  function\n");
    for (fields.items) |f| {
        try ml_out.print(arena, "  | Domain_{s} -> idx__{s}\n", .{ f, f });
    }

    var mli_out: std.ArrayList(u8) = .empty;
    try mli_out.appendSlice(arena, "val stack_ctx_words : int\n\ntype t =\n");
    for (fields.items) |f| {
        try mli_out.print(arena, "  | Domain_{s}\n", .{f});
    }
    try mli_out.appendSlice(arena, "\nval idx_of_field : t -> int\n");

    try self.domainstate_ml.writeAll(io, ml_out.items);
    try self.domainstate_mli.writeAll(io, mli_out.items);
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
                    try out.print(arena, "  {s};\n", .{quoted});
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
        try out.print(arena, "  \"{s}\";\n", .{line});
    }
    try out.appendSlice(arena, "|]\n");

    try self.runtimedef_ml.writeAll(io, out.items);
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
        try self.menhir_lib_mli.writeAll(io, buf.items);
    }
    {
        const ml_raw = try root_dir.readFileAlloc(io, "boot/menhir/parser.ml", gpa, .unlimited);
        defer gpa.free(ml_raw);
        const replaced = try std.mem.replaceOwned(u8, gpa, ml_raw, "MenhirLib", "CamlinternalMenhirLib");
        defer gpa.free(replaced);
        try self.parser_ml.writeAll(io, replaced);
    }
    {
        const mli_raw = try root_dir.readFileAlloc(io, "boot/menhir/parser.mli", gpa, .unlimited);
        defer gpa.free(mli_raw);
        const replaced = try std.mem.replaceOwned(u8, gpa, mli_raw, "MenhirLib", "CamlinternalMenhirLib");
        defer gpa.free(replaced);
        try self.parser_mli.writeAll(io, replaced);
    }
}

/// Splice `build/compiler/ccomp_zig_cache.ml` into `utils/ccomp.ml`.
fn generateCcomp(self: *GenCompilerSources, io: std.Io, arena: std.mem.Allocator, root_dir: std.Io.Dir) !void {
    var ccomp: []const u8 = try root_dir.readFileAlloc(io, "utils/ccomp.ml", arena, .unlimited);
    const fragment = try self.ccomp_zig_cache_ml.readAll(io, arena);
    ccomp = try replaceOnce(arena, ccomp, "let command cmdline =\n", try std.mem.concat(arena, u8, &.{
        fragment,
        "let command cmdline =\n",
    }));
    ccomp = try replaceOnce(arena, ccomp, "  let res = Sys.command cmdline in\n", "  let res = Sys.command (with_zig_cache cmdline) in\n");
    try self.ccomp_ml.writeAll(io, ccomp);
}
