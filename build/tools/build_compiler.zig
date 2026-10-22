const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const InputDir = utils.InputDir;
const OutputDir = utils.OutputDir;

const Self = @This();

ocamlrun: InputFile,
boot_ocamlc: InputFile,
boot_ocamllex: InputFile,
ocamlyacc: InputFile,
primitives: InputFile,
stdlib_dir: InputDir,
ocaml_src_dir: InputDir,
config_main_ml: InputFile,
config_boot_ml: InputFile,
compilerlibs_meta: InputFile,
arch: []const u8,
arch64: bool = false,
strict_yacc: bool = false,
has_set_runtime_default: bool = false,
host_libdir: []const u8 = "../lib/ocaml",
launch_method: []const u8 = "sh /usr/local/bin",
runtime_search: []const u8 = "enable",
compflags: []const []const u8 = &.{},
include_dirs: []const []const u8 = &.{},
arch_specific_files: []const []const u8 = &.{},
pervasives_modules: []const []const u8 = &.{},
ocamlcommon_cmos: []const []const u8 = &.{},
ocamlcommon_cmis: []const []const u8 = &.{},
ocamlbytecomp_cmos: []const []const u8 = &.{},
ocamlmiddleend_cmos: []const []const u8 = &.{},
ocamlmiddleend_cmis: []const []const u8 = &.{},
ocamloptcomp_cmos: []const []const u8 = &.{},
ocamloptcomp_cmis: []const []const u8 = &.{},
ocamltoplevel_cmos: []const []const u8 = &.{},
ocamllex_cmos: []const []const u8 = &.{},
ocamlprof_cmos: []const []const u8 = &.{},
ocamlcp_cmos: []const []const u8 = &.{},
ocamloptp_cmos: []const []const u8 = &.{},
ocamlmklib_cmos: []const []const u8 = &.{},
ocamlmktop_cmos: []const []const u8 = &.{},
out_dir: OutputDir,

const source_subdirs = [_][]const u8{
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
    "toplevel/byte",
    "toplevel/native",
    "tools",
    "lex",
};

pub fn run(self: *Self, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_dir_handle = try self.out_dir.open(io, .{});
    defer out_dir_handle.close(io);

    const out_dir_path = self.out_dir.path();
    const src_root_path = self.ocaml_src_dir.path();

    // 1. Create directory structure and copy .mli/.ml/.mll/.mly sources
    for (source_subdirs) |subdir| {
        try copySubdirSources(io, gpa, src_root_path, out_dir_handle, subdir);
    }
    try out_dir_handle.createDirPath(io, "compilerlibs");
    try out_dir_handle.createDirPath(io, "bin");

    // 2. Copy ARCH_SPECIFIC files from asmcomp/$(ARCH)/ into asmcomp/
    for (self.arch_specific_files) |arch_file| {
        const basename = std.fs.path.basename(arch_file);
        const src_rel = try std.fmt.allocPrint(arena, "asmcomp/{s}/{s}", .{ self.arch, basename });
        try copyFileRel(io, gpa, src_root_path, src_rel, out_dir_handle, arch_file);
    }

    // 3. Copy toplevel shared .mli files into toplevel/byte and toplevel/native
    const shared_mlis = [_][]const u8{ "topeval.mli", "trace.mli", "topmain.mli" };
    for (shared_mlis) |mli_name| {
        const src_rel = try std.fmt.allocPrint(arena, "toplevel/{s}", .{mli_name});
        const byte_rel = try std.fmt.allocPrint(arena, "toplevel/byte/{s}", .{mli_name});
        const nat_rel = try std.fmt.allocPrint(arena, "toplevel/native/{s}", .{mli_name});
        try copyFileRel(io, gpa, src_root_path, src_rel, out_dir_handle, byte_rel);
        try copyFileRel(io, gpa, src_root_path, src_rel, out_dir_handle, nat_rel);
    }

    // 4. Write config_main.ml, config_boot.ml, config.ml, config_main.mli, config_boot.mli, compilerlibs/META
    {
        const main_bytes = try self.config_main_ml.readAll(io, gpa);
        defer gpa.free(main_bytes);
        try out_dir_handle.writeFile(io, .{ .sub_path = "utils/config_main.ml", .data = main_bytes });
        try out_dir_handle.writeFile(io, .{ .sub_path = "utils/config.ml", .data = main_bytes });

        const boot_bytes = try self.config_boot_ml.readAll(io, gpa);
        defer gpa.free(boot_bytes);
        try out_dir_handle.writeFile(io, .{ .sub_path = "utils/config_boot.ml", .data = boot_bytes });

        try copyFileRel(io, gpa, src_root_path, "utils/config.mli", out_dir_handle, "utils/config_main.mli");
        try copyFileRel(io, gpa, src_root_path, "utils/config.mli", out_dir_handle, "utils/config_boot.mli");

        const meta_bytes = try self.compilerlibs_meta.readAll(io, gpa);
        defer gpa.free(meta_bytes);
        try out_dir_handle.writeFile(io, .{ .sub_path = "compilerlibs/META", .data = meta_bytes });
    }

    // 5. Generate utils/domainstate.ml and utils/domainstate.mli
    try self.generateDomainstate(io, gpa, arena, src_root_path, out_dir_handle);

    // 6. Generate lambda/runtimedef.ml
    try self.generateRuntimedef(io, gpa, arena, src_root_path, out_dir_handle);

    // 7. Generate parsing/camlinternalMenhirLib.{ml,mli} and parsing/parser.{ml,mli}
    try generateMenhirParser(io, gpa, arena, src_root_path, out_dir_handle);

    // 8. Run ocamlyacc on lex/parser.mly and boot/ocamllex on .mll files
    try self.runLexAndYaccGenerators(io, gpa, arena, out_dir_handle, out_dir_path);

    // 9. Compile and run tools/make_opcodes and tools/cvt_emit
    try self.runMakeOpcodesAndCvtEmit(io, gpa, arena, src_root_path, out_dir_handle, out_dir_path);

    // 10. Parse .depend and compile all required .cmi and .cmo files in parallel waves
    var dep_map = try self.loadDependMap(io, gpa, arena, src_root_path);
    try self.compileAllUnitsTopological(io, gpa, arena, out_dir_handle, out_dir_path, &dep_map);

    // 11. Link compilerlibs/*.cma
    try self.linkBytecodeLibrary(io, gpa, arena, out_dir_path, "compilerlibs/ocamlcommon.cma", self.ocamlcommon_cmos, &.{"-linkall"});
    try self.linkBytecodeLibrary(io, gpa, arena, out_dir_path, "compilerlibs/ocamlbytecomp.cma", self.ocamlbytecomp_cmos, &.{});
    try self.linkBytecodeLibrary(io, gpa, arena, out_dir_path, "compilerlibs/ocamlmiddleend.cma", self.ocamlmiddleend_cmos, &.{});
    try self.linkBytecodeLibrary(io, gpa, arena, out_dir_path, "compilerlibs/ocamloptcomp.cma", self.ocamloptcomp_cmos, &.{});
    try self.linkBytecodeLibrary(io, gpa, arena, out_dir_path, "compilerlibs/ocamltoplevel.cma", self.ocamltoplevel_cmos, &.{
        "-I",
        try std.fmt.allocPrint(arena, "{s}/toplevel/byte", .{out_dir_path}),
    });

    // 12. Link bytecode compilers and tools
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/ocamlc.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "driver/main.cmo" },
        &.{ "-compat-32", "-g" },
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/ocamlopt.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamloptcomp.cma", "driver/optmain.cmo" },
        &.{"-g"},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/ocamllex.byte",
        self.ocamllex_cmos,
        &.{"-compat-32"},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/expunge.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "toplevel/expunge.cmo" },
        &.{},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/ocamldep.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "tools/ocamldep.cmo" },
        &.{"-compat-32"},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/ocamlobjinfo.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "compilerlibs/ocamlmiddleend.cma", "tools/objinfo.cmo" },
        &.{},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/ocamlcmt.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "tools/ocamlcmt.cmo" },
        &.{},
    );
    try self.linkBytecodeProgram(io, gpa, arena, out_dir_path, "bin/ocamlprof.byte", self.ocamlprof_cmos, &.{});
    try self.linkBytecodeProgram(io, gpa, arena, out_dir_path, "bin/ocamlcp.byte", self.ocamlcp_cmos, &.{});
    try self.linkBytecodeProgram(io, gpa, arena, out_dir_path, "bin/ocamloptp.byte", self.ocamloptp_cmos, &.{});
    try self.linkBytecodeProgram(io, gpa, arena, out_dir_path, "bin/ocamlmklib.byte", self.ocamlmklib_cmos, &.{});
    try self.linkBytecodeProgram(io, gpa, arena, out_dir_path, "bin/ocamlmktop.byte", self.ocamlmktop_cmos, &.{});
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/dumpobj.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "tools/opnames.cmo", "tools/dumpobj.cmo" },
        &.{},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/primreq.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "tools/primreq.cmo" },
        &.{},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/stripdebug.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "tools/stripdebug.cmo" },
        &.{},
    );
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "bin/cmpbyt.byte",
        &.{ "compilerlibs/ocamlcommon.cma", "compilerlibs/ocamlbytecomp.cma", "tools/cmpbyt.cmo" },
        &.{},
    );

    // 13. Link ocaml.tmp and run expunge.byte to produce bin/ocaml
    try self.linkBytecodeProgram(
        io,
        gpa,
        arena,
        out_dir_path,
        "ocaml.tmp",
        &.{
            "compilerlibs/ocamlcommon.cma",
            "compilerlibs/ocamlbytecomp.cma",
            "compilerlibs/ocamltoplevel.cma",
            "toplevel/topstart.cmo",
        },
        &.{
            "-I",
            try std.fmt.allocPrint(arena, "{s}/toplevel/byte", .{out_dir_path}),
            "-linkall",
            "-g",
        },
    );
    {
        var exp_argv: std.ArrayList([]const u8) = .empty;
        const ocaml_out = try std.fmt.allocPrint(arena, "{s}/bin/ocaml", .{out_dir_path});
        try exp_argv.appendSlice(arena, &.{
            self.ocamlrun.path(),
            try std.fmt.allocPrint(arena, "{s}/bin/expunge.byte", .{out_dir_path}),
            try std.fmt.allocPrint(arena, "{s}/ocaml.tmp", .{out_dir_path}),
            ocaml_out,
        });
        try exp_argv.appendSlice(arena, self.pervasives_modules);
        try runChecked(io, gpa, exp_argv.items);
        if (std.Io.Dir.cwd().openFile(io, ocaml_out, .{})) |f| {
            defer f.close(io);
            _ = f.setPermissions(io, .executable_file) catch {};
        } else |_| {}
    }
}

fn copySubdirSources(
    io: std.Io,
    gpa: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
    subdir: []const u8,
) !void {
    try out_dir_handle.createDirPath(io, subdir);
    const full_src_subdir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ src_root_path, subdir });
    defer gpa.free(full_src_subdir);

    var src_dir = std.Io.Dir.cwd().openDir(io, full_src_subdir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close(io);

    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (std.mem.eql(u8, ext, ".ml") or
            std.mem.eql(u8, ext, ".mli") or
            std.mem.eql(u8, ext, ".mll") or
            std.mem.eql(u8, ext, ".mly"))
        {
            const data = try src_dir.readFileAlloc(io, entry.name, gpa, .unlimited);
            defer gpa.free(data);
            const dest_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ subdir, entry.name });
            defer gpa.free(dest_rel);
            try out_dir_handle.writeFile(io, .{ .sub_path = dest_rel, .data = data });
        }
    }
}

fn copyFileRel(
    io: std.Io,
    gpa: std.mem.Allocator,
    src_root_path: []const u8,
    src_rel: []const u8,
    out_dir_handle: std.Io.Dir,
    dest_rel: []const u8,
) !void {
    const full_src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ src_root_path, src_rel });
    defer gpa.free(full_src);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, full_src, gpa, .unlimited);
    defer gpa.free(data);
    try out_dir_handle.writeFile(io, .{ .sub_path = dest_rel, .data = data });
}

fn generateDomainstate(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
) !void {
    const tbl_path = try std.fmt.allocPrint(arena, "{s}/runtime/caml/domain_state.tbl", .{src_root_path});
    const tbl_src = try std.Io.Dir.cwd().readFileAlloc(io, tbl_path, gpa, .unlimited);
    defer gpa.free(tbl_src);

    const cfg_h_path = try std.fmt.allocPrint(arena, "{s}/runtime/caml/config.h", .{src_root_path});
    const cfg_h_src = try std.Io.Dir.cwd().readFileAlloc(io, cfg_h_path, gpa, .unlimited);
    defer gpa.free(cfg_h_src);

    // Safety check against runtime/caml/config.h
    if (std.mem.indexOf(u8, cfg_h_src, "#define Stack_ctx_words (6 + 1)") == null or
        std.mem.indexOf(u8, cfg_h_src, "#define Stack_ctx_words (6 + 2)") == null)
    {
        @panic("domainstate safety check failed: unexpected Stack_ctx_words definition in runtime/caml/config.h");
    }

    var fields: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, tbl_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "DOMAIN_STATE(")) {
            const inner = line["DOMAIN_STATE(".len..];
            const comma_idx = std.mem.indexOfScalar(u8, inner, ',') orelse {
                std.debug.panic("Malformed DOMAIN_STATE in domain_state.tbl: '{s}'", .{line});
            };
            const close_idx = std.mem.indexOfScalarPos(u8, inner, comma_idx + 1, ')') orelse {
                std.debug.panic("Malformed DOMAIN_STATE ')' in domain_state.tbl: '{s}'", .{line});
            };
            const field_name = std.mem.trim(u8, inner[comma_idx + 1 .. close_idx], " \t");
            try fields.append(arena, field_name);
        }
    }

    if (fields.items.len == 0) {
        @panic("domainstate safety check failed: 0 DOMAIN_STATE entries found in runtime/caml/domain_state.tbl");
    }

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

    try out_dir_handle.writeFile(io, .{ .sub_path = "utils/domainstate.ml", .data = ml_out.items });
    try out_dir_handle.writeFile(io, .{ .sub_path = "utils/domainstate.mli", .data = mli_out.items });
}

fn generateRuntimedef(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
) !void {
    const fail_h_path = try std.fmt.allocPrint(arena, "{s}/runtime/caml/fail.h", .{src_root_path});
    const fail_h_src = try std.Io.Dir.cwd().readFileAlloc(io, fail_h_path, gpa, .unlimited);
    defer gpa.free(fail_h_src);

    const prims_src = try self.primitives.readAll(io, gpa);
    defer gpa.free(prims_src);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "let builtin_exceptions = [|\n");

    var exn_count: usize = 0;
    var fail_lines = std.mem.splitScalar(u8, fail_h_src, '\n');
    while (fail_lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        // Match sed pattern: `s|.*/\* \("[A-Za-z_]*"\) \*/$|  \1;|p`
        if (std.mem.endsWith(u8, line, "\" */")) {
            if (std.mem.lastIndexOf(u8, line, "/* \"")) |comment_idx| {
                const quoted = line[comment_idx + 3 .. line.len - 3]; // includes surrounding quotes
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
    if (exn_count == 0) {
        @panic("runtimedef safety check failed: 0 builtin_exceptions extracted from runtime/caml/fail.h");
    }
    try out.appendSlice(arena, "|]\nlet builtin_primitives = [|\n");

    var prim_lines = std.mem.splitScalar(u8, prims_src, '\n');
    while (prim_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "  \"{s}\";\n", .{line}));
    }
    try out.appendSlice(arena, "|]\n");

    try out_dir_handle.writeFile(io, .{ .sub_path = "lambda/runtimedef.ml", .data = out.items });
}

fn generateMenhirParser(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
) !void {
    try copyFileRel(io, gpa, src_root_path, "boot/menhir/menhirLib.ml", out_dir_handle, "parsing/camlinternalMenhirLib.ml");

    {
        const mli_path = try std.fmt.allocPrint(arena, "{s}/boot/menhir/menhirLib.mli", .{src_root_path});
        const mli_raw = try std.Io.Dir.cwd().readFileAlloc(io, mli_path, gpa, .unlimited);
        defer gpa.free(mli_raw);
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, "[@@@ocaml.warning \"-67\"]\n");
        try buf.appendSlice(arena, mli_raw);
        try out_dir_handle.writeFile(io, .{ .sub_path = "parsing/camlinternalMenhirLib.mli", .data = buf.items });
    }

    const parser_files = [_][2][]const u8{
        .{ "boot/menhir/parser.ml", "parsing/parser.ml" },
        .{ "boot/menhir/parser.mli", "parsing/parser.mli" },
    };
    for (parser_files) |pair| {
        const full_src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_root_path, pair[0] });
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, full_src, gpa, .unlimited);
        defer gpa.free(raw);
        const replaced = try std.mem.replaceOwned(u8, gpa, raw, "MenhirLib", "CamlinternalMenhirLib");
        defer gpa.free(replaced);
        try out_dir_handle.writeFile(io, .{ .sub_path = pair[1], .data = replaced });
    }
}

fn runLexAndYaccGenerators(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
) !void {
    // 1. ocamlyacc on lex/parser.mly
    {
        var yacc_argv: std.ArrayList([]const u8) = .empty;
        try yacc_argv.append(arena, self.ocamlyacc.path());
        if (self.strict_yacc) {
            try yacc_argv.append(arena, "--strict");
        }
        try yacc_argv.appendSlice(arena, &.{
            "-v",
            try std.fmt.allocPrint(arena, "{s}/lex/parser.mly", .{out_dir_path}),
        });
        try runChecked(io, gpa, yacc_argv.items);
    }

    // 2. boot/ocamllex on .mll files
    const mll_files = [_][]const u8{
        "lex/lexer.mll",
        "parsing/lexer.mll",
        "bytecomp/byterntm.mll",
        "tools/make_opcodes.mll",
        "tools/cvt_emit.mll",
    };
    for (mll_files) |mll_rel| {
        if (!fileExistsInDir(io, out_dir_handle, mll_rel)) continue;
        try runChecked(io, gpa, &.{
            self.ocamlrun.path(),
            self.boot_ocamllex.path(),
            "-q",
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, mll_rel }),
        });
    }
}

fn runMakeOpcodesAndCvtEmit(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
) !void {
    const tools_dir = try std.fmt.allocPrint(arena, "{s}/tools", .{out_dir_path});

    // Compile tools/make_opcodes and tools/cvt_emit
    const helper_tools = [_][]const u8{ "make_opcodes", "cvt_emit" };
    for (helper_tools) |tname| {
        const mli_rel = try std.fmt.allocPrint(arena, "tools/{s}.mli", .{tname});
        if (fileExistsInDir(io, out_dir_handle, mli_rel)) {
            var mli_argv: std.ArrayList([]const u8) = .empty;
            try self.appendBaseOcamlc(arena, &mli_argv);
            try mli_argv.appendSlice(arena, &.{
                "-I",
                tools_dir,
                "-c",
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, mli_rel }),
            });
            try runChecked(io, gpa, mli_argv.items);
        }

        const ml_path = try std.fmt.allocPrint(arena, "{s}/tools/{s}.ml", .{ out_dir_path, tname });
        const cmo_path = try std.fmt.allocPrint(arena, "{s}/tools/{s}.cmo", .{ out_dir_path, tname });
        const exe_path = try std.fmt.allocPrint(arena, "{s}/tools/{s}.byte", .{ out_dir_path, tname });

        {
            var ml_argv: std.ArrayList([]const u8) = .empty;
            try self.appendBaseOcamlc(arena, &ml_argv);
            try ml_argv.appendSlice(arena, &.{ "-I", tools_dir, "-c", ml_path });
            try runChecked(io, gpa, ml_argv.items);
        }
        {
            var link_argv: std.ArrayList([]const u8) = .empty;
            try self.appendBaseOcamlc(arena, &link_argv);
            if (self.has_set_runtime_default) {
                try link_argv.appendSlice(arena, &.{
                    "-launch-method",
                    self.launch_method,
                    "-runtime-search",
                    self.runtime_search,
                });
            }
            try link_argv.appendSlice(arena, &.{ "-o", exe_path, cmo_path });
            try runChecked(io, gpa, link_argv.items);
        }
    }

    const instruct_h_path = try std.fmt.allocPrint(arena, "{s}/runtime/caml/instruct.h", .{src_root_path});
    const instruct_bytes = try std.Io.Dir.cwd().readFileAlloc(io, instruct_h_path, gpa, .unlimited);
    defer gpa.free(instruct_bytes);

    const make_opcodes_exe = try std.fmt.allocPrint(arena, "{s}/tools/make_opcodes.byte", .{out_dir_path});

    // bytecomp/opcodes.ml
    {
        const opcodes_ml = try runWithStdinCaptureStdout(io, gpa, &.{
            self.ocamlrun.path(),
            make_opcodes_exe,
            "-opcodes",
        }, instruct_bytes);
        defer gpa.free(opcodes_ml);
        try out_dir_handle.writeFile(io, .{ .sub_path = "bytecomp/opcodes.ml", .data = opcodes_ml });
    }

    // bytecomp/opcodes.mli (via ocamlc -i)
    {
        var intf_argv: std.ArrayList([]const u8) = .empty;
        try self.appendBaseOcamlc(arena, &intf_argv);
        try intf_argv.appendSlice(arena, &.{
            "-i",
            try std.fmt.allocPrint(arena, "{s}/bytecomp/opcodes.ml", .{out_dir_path}),
        });
        const opcodes_mli = try runWithStdinCaptureStdout(io, gpa, intf_argv.items, "");
        defer gpa.free(opcodes_mli);
        try out_dir_handle.writeFile(io, .{ .sub_path = "bytecomp/opcodes.mli", .data = opcodes_mli });
    }

    // tools/opnames.ml
    {
        const opnames_ml = try runWithStdinCaptureStdout(io, gpa, &.{
            self.ocamlrun.path(),
            make_opcodes_exe,
            "-opnames",
        }, instruct_bytes);
        defer gpa.free(opnames_ml);
        try out_dir_handle.writeFile(io, .{ .sub_path = "tools/opnames.ml", .data = opnames_ml });
    }

    // asmcomp/emit.ml (from asmcomp/$(ARCH)/emit.mlp via tools/cvt_emit.byte)
    {
        const emit_mlp_path = try std.fmt.allocPrint(arena, "{s}/asmcomp/{s}/emit.mlp", .{ src_root_path, self.arch });
        const emit_mlp_bytes = try std.Io.Dir.cwd().readFileAlloc(io, emit_mlp_path, gpa, .unlimited);
        defer gpa.free(emit_mlp_bytes);

        const cvt_emit_exe = try std.fmt.allocPrint(arena, "{s}/tools/cvt_emit.byte", .{out_dir_path});
        const emit_body = try runWithStdinCaptureStdout(io, gpa, &.{
            self.ocamlrun.path(),
            cvt_emit_exe,
        }, emit_mlp_bytes);
        defer gpa.free(emit_body);

        var emit_full: std.ArrayList(u8) = .empty;
        try emit_full.appendSlice(arena, try std.fmt.allocPrint(arena, "# 1 \"asmcomp/{s}/emit.mlp\"\n", .{self.arch}));
        try emit_full.appendSlice(arena, emit_body);
        try out_dir_handle.writeFile(io, .{ .sub_path = "asmcomp/emit.ml", .data = emit_full.items });
    }
}

fn loadDependMap(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
) !std.StringHashMapUnmanaged([]const []const u8) {
    var map: std.StringHashMapUnmanaged([]const []const u8) = .empty;

    const root_dep_path = try std.fmt.allocPrint(arena, "{s}/.depend", .{src_root_path});
    const root_dep_src = try std.Io.Dir.cwd().readFileAlloc(io, root_dep_path, gpa, .unlimited);
    defer gpa.free(root_dep_src);
    try parseDependInto(arena, root_dep_src, self.arch, "", &map);

    // In OCaml 5.0, lex/.depend and tools/.depend are separate files
    const extra_deps = [_][2][]const u8{
        .{ "lex/.depend", "lex/" },
        .{ "tools/.depend", "tools/" },
    };
    for (extra_deps) |pair| {
        const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src_root_path, pair[0] });
        if (std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .unlimited)) |src| {
            defer gpa.free(src);
            try parseDependInto(arena, src, self.arch, pair[1], &map);
        } else |_| {}
    }

    return map;
}

fn parseDependInto(
    arena: std.mem.Allocator,
    depend_src: []const u8,
    active_arch: []const u8,
    subdir_prefix: []const u8,
    map: *std.StringHashMapUnmanaged([]const []const u8),
) !void {
    var joined_line: std.ArrayList(u8) = .empty;
    var cond_active = true;

    var lines = std.mem.splitScalar(u8, depend_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

        if (joined_line.items.len == 0) {
            if (std.mem.startsWith(u8, trimmed, "ifeq ")) {
                // Format: ifeq "$(ARCH)" "amd64"
                const rest = std.mem.trim(u8, trimmed["ifeq ".len..], " \t");
                if (std.mem.startsWith(u8, rest, "\"$(ARCH)\"")) {
                    const rhs = std.mem.trim(u8, rest["\"$(ARCH)\"".len..], " \t\"");
                    cond_active = std.mem.eql(u8, rhs, active_arch);
                }
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "endif")) {
                cond_active = true;
                continue;
            }
        }

        if (!cond_active) continue;

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
                const norm_dep = try normalizeDependToken(arena, subdir_prefix, dep_tok);
                try deps.append(arena, norm_dep);
            }
        }

        var lhs_it = std.mem.tokenizeAny(u8, lhs, " \t");
        while (lhs_it.next()) |target_tok| {
            if (std.mem.endsWith(u8, target_tok, ".cmi") or std.mem.endsWith(u8, target_tok, ".cmo")) {
                const norm_target = try normalizeDependToken(arena, subdir_prefix, target_tok);
                try map.put(arena, norm_target, deps.items);
            }
        }
    }
}

fn normalizeDependToken(arena: std.mem.Allocator, subdir_prefix: []const u8, tok: []const u8) ![]const u8 {
    if (subdir_prefix.len == 0) return tok;
    if (std.mem.startsWith(u8, tok, "../")) {
        return tok["../".len..];
    }
    if (std.mem.indexOfScalar(u8, tok, '/') == null) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ subdir_prefix, tok });
    }
    return tok;
}

fn compileAllUnitsTopological(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    dep_map: *const std.StringHashMapUnmanaged([]const []const u8),
) !void {
    // 1. Gather all root .cmo and .cmi targets
    var ordered_targets: std.ArrayList([]const u8) = .empty;
    var target_set: std.StringHashMapUnmanaged(void) = .empty;

    const addTarget = struct {
        fn call(
            a: std.mem.Allocator,
            io_ctx: std.Io,
            dir: std.Io.Dir,
            list: *std.ArrayList([]const u8),
            set: *std.StringHashMapUnmanaged(void),
            t: []const u8,
        ) !void {
            if (set.contains(t)) return;
            // If t is a .cmi whose .mli does not exist, skip adding the .cmi (its .cmo produces both)
            if (std.mem.endsWith(u8, t, ".cmi")) {
                const mli_rel = try std.fmt.allocPrint(a, "{s}.mli", .{t[0 .. t.len - 4]});
                if (!fileExistsInDir(io_ctx, dir, mli_rel)) return;
            }
            try set.put(a, t, {});
            try list.append(a, t);

            // If t is a .cmo and has a corresponding .mli, ensure its .cmi is also in the build set
            if (std.mem.endsWith(u8, t, ".cmo")) {
                const base = t[0 .. t.len - 4];
                const mli_rel = try std.fmt.allocPrint(a, "{s}.mli", .{base});
                if (fileExistsInDir(io_ctx, dir, mli_rel)) {
                    const cmi_rel = try std.fmt.allocPrint(a, "{s}.cmi", .{base});
                    if (!set.contains(cmi_rel)) {
                        try set.put(a, cmi_rel, {});
                        try list.append(a, cmi_rel);
                    }
                }
            }
        }
    }.call;

    const slices_to_add = [_][]const []const u8{
        self.ocamlcommon_cmis,
        self.ocamlcommon_cmos,
        &.{ "utils/config_main.cmo", "utils/config_boot.cmo" },
        self.ocamlbytecomp_cmos,
        self.ocamlmiddleend_cmis,
        self.ocamlmiddleend_cmos,
        self.ocamloptcomp_cmis,
        self.ocamloptcomp_cmos,
        &.{ "toplevel/topeval.cmi", "toplevel/trace.cmi", "toplevel/topmain.cmi" },
        self.ocamltoplevel_cmos,
        self.ocamllex_cmos,
        self.ocamlprof_cmos,
        self.ocamlcp_cmos,
        self.ocamloptp_cmos,
        self.ocamlmklib_cmos,
        self.ocamlmktop_cmos,
        &.{
            "driver/main.cmo",
            "driver/optmain.cmo",
            "toplevel/topstart.cmo",
            "toplevel/expunge.cmo",
            "tools/ocamldep.cmo",
            "tools/objinfo.cmo",
            "tools/ocamlcmt.cmo",
            "tools/opnames.cmo",
            "tools/dumpobj.cmo",
            "tools/primreq.cmo",
            "tools/stripdebug.cmo",
            "tools/cmpbyt.cmo",
            "tools/profiling.cmo",
        },
    };
    for (slices_to_add) |slice| {
        for (slice) |item| {
            try addTarget(arena, io, out_dir_handle, &ordered_targets, &target_set, item);
        }
    }

    // 2. Transitively pull in any .cmi / .cmo dependencies from dep_map
    var scan_idx: usize = 0;
    while (scan_idx < ordered_targets.items.len) : (scan_idx += 1) {
        const cur = ordered_targets.items[scan_idx];
        if (dep_map.get(cur)) |deps| {
            for (deps) |dep| {
                // Skip x86_* dependencies when building for non-x86 architectures (relevant for 5.0/5.1 .depend)
                if (!std.mem.eql(u8, self.arch, "amd64") and !std.mem.eql(u8, self.arch, "i386")) {
                    if (std.mem.startsWith(u8, dep, "asmcomp/x86_")) continue;
                }
                if (std.mem.endsWith(u8, dep, ".cmi")) {
                    const base = dep[0 .. dep.len - 4];
                    const mli_rel = try std.fmt.allocPrint(arena, "{s}.mli", .{base});
                    if (fileExistsInDir(io, out_dir_handle, mli_rel)) {
                        try addTarget(arena, io, out_dir_handle, &ordered_targets, &target_set, dep);
                    } else {
                        const cmo_rel = try std.fmt.allocPrint(arena, "{s}.cmo", .{base});
                        try addTarget(arena, io, out_dir_handle, &ordered_targets, &target_set, cmo_rel);
                    }
                } else {
                    try addTarget(arena, io, out_dir_handle, &ordered_targets, &target_set, dep);
                }
            }
        }
    }

    // 3. Execute topological compilation waves
    const total = ordered_targets.items.len;
    var done = try arena.alloc(bool, total);
    @memset(done, false);
    var built_set: std.StringHashMapUnmanaged(void) = .empty;

    var completed: usize = 0;
    while (completed < total) {
        var wave_cmds: std.ArrayList([]const []const u8) = .empty;
        var wave_indices: std.ArrayList(usize) = .empty;

        for (ordered_targets.items, 0..) |target, i| {
            if (done[i]) continue;

            var ready = true;

            // If target is a .cmo and its .cmi is in target_set, wait for .cmi first
            if (std.mem.endsWith(u8, target, ".cmo")) {
                const cmi_peer = try std.fmt.allocPrint(arena, "{s}.cmi", .{target[0 .. target.len - 4]});
                if (target_set.contains(cmi_peer) and !built_set.contains(cmi_peer)) {
                    ready = false;
                }
            }

            // If target is toplevel/byte/{topeval,trace,topmain}.cmi, it is produced by copying toplevel/*.cmi
            if (ready) {
                if (isToplevelSharedByteCmi(target)) |parent_cmi| {
                    if (!built_set.contains(parent_cmi)) {
                        ready = false;
                    }
                }
            }

            if (ready) {
                if (dep_map.get(target)) |deps| {
                    for (deps) |dep| {
                        if (std.mem.eql(u8, dep, target)) continue;
                        if (target_set.contains(dep)) {
                            if (!built_set.contains(dep)) {
                                ready = false;
                                break;
                            }
                        } else if (std.mem.endsWith(u8, dep, ".cmi")) {
                            const cmo_alt = try std.fmt.allocPrint(arena, "{s}.cmo", .{dep[0 .. dep.len - 4]});
                            if (target_set.contains(cmo_alt) and !built_set.contains(cmo_alt)) {
                                ready = false;
                                break;
                            }
                        }
                    }
                }
            }

            if (!ready) continue;

            if (isToplevelSharedByteCmi(target)) |_| {
                // Handled by copy right after parent wave; mark ready in this wave with no external command
                try wave_indices.append(arena, i);
            } else {
                const argv = try self.buildUnitCompileArgv(arena, out_dir_path, target);
                try wave_cmds.append(arena, argv);
                try wave_indices.append(arena, i);
            }
        }

        if (wave_indices.items.len == 0) {
            for (ordered_targets.items, 0..) |t, idx| {
                if (!done[idx]) {
                    std.log.err("Unresolved compiler build target: {s}", .{t});
                }
            }
            @panic("Compiler .depend safety check failed: dependency cycle or unresolved target");
        }

        if (wave_cmds.items.len > 0) {
            try runCommandsInParallelBatches(io, gpa, wave_cmds.items, 16);
        }

        for (wave_indices.items) |idx| {
            const target = ordered_targets.items[idx];
            done[idx] = true;
            try built_set.put(arena, target, {});
            completed += 1;

            // If we just built toplevel/{topeval,trace,topmain}.cmi, copy it to toplevel/byte/ and toplevel/native/
            if (std.mem.eql(u8, target, "toplevel/topeval.cmi") or
                std.mem.eql(u8, target, "toplevel/trace.cmi") or
                std.mem.eql(u8, target, "toplevel/topmain.cmi"))
            {
                const basename = std.fs.path.basename(target);
                const data = try out_dir_handle.readFileAlloc(io, target, gpa, .unlimited);
                defer gpa.free(data);
                const byte_dest = try std.fmt.allocPrint(arena, "toplevel/byte/{s}", .{basename});
                const nat_dest = try std.fmt.allocPrint(arena, "toplevel/native/{s}", .{basename});
                try out_dir_handle.writeFile(io, .{ .sub_path = byte_dest, .data = data });
                try out_dir_handle.writeFile(io, .{ .sub_path = nat_dest, .data = data });
            }
        }
    }
}

fn isToplevelSharedByteCmi(target: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, target, "toplevel/byte/topeval.cmi")) return "toplevel/topeval.cmi";
    if (std.mem.eql(u8, target, "toplevel/byte/trace.cmi")) return "toplevel/trace.cmi";
    if (std.mem.eql(u8, target, "toplevel/byte/topmain.cmi")) return "toplevel/topmain.cmi";
    return null;
}

fn buildUnitCompileArgv(
    self: *Self,
    arena: std.mem.Allocator,
    out_dir_path: []const u8,
    target: []const u8,
) ![]const []const u8 {
    const is_cmi = std.mem.endsWith(u8, target, ".cmi");
    const base = target[0 .. target.len - 4];
    const src_rel = try std.fmt.allocPrint(arena, "{s}.{s}", .{ base, if (is_cmi) "mli" else "ml" });
    const src_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, src_rel });
    const out_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, target });
    const target_dir = std.fs.path.dirname(target) orelse ".";
    const target_dir_full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, target_dir });

    var argv: std.ArrayList([]const u8) = .empty;
    try self.appendBaseOcamlc(arena, &argv);
    try argv.appendSlice(arena, self.compflags);

    // Put -I $(@D) first so local directory modules (e.g., lex/parser.cmi) take precedence
    try argv.appendSlice(arena, &.{ "-I", target_dir_full });

    // For non-lex directories, add all compiler INCLUDE directories
    if (!std.mem.eql(u8, target_dir, "lex")) {
        for (self.include_dirs) |inc| {
            try argv.appendSlice(arena, &.{
                "-I",
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, inc }),
            });
        }
    }

    try argv.appendSlice(arena, &.{ "-o", out_path, "-c", src_path });
    return argv.items;
}

fn linkBytecodeLibrary(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_path: []const u8,
    cma_rel: []const u8,
    cmos: []const []const u8,
    extra_flags: []const []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try self.appendBaseOcamlc(arena, &argv);
    for (self.include_dirs) |inc| {
        try argv.appendSlice(arena, &.{
            "-I",
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, inc }),
        });
    }
    try argv.appendSlice(arena, extra_flags);
    try argv.appendSlice(arena, &.{
        "-a",
        "-o",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, cma_rel }),
    });
    for (cmos) |cmo_rel| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, cmo_rel }));
    }
    try runChecked(io, gpa, argv.items);
}

fn linkBytecodeProgram(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_dir_path: []const u8,
    exe_rel: []const u8,
    objs: []const []const u8,
    extra_flags: []const []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try self.appendBaseOcamlc(arena, &argv);
    for (self.include_dirs) |inc| {
        try argv.appendSlice(arena, &.{
            "-I",
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, inc }),
        });
    }
    if (self.has_set_runtime_default) {
        try argv.appendSlice(arena, &.{
            "-set-runtime-default",
            try std.fmt.allocPrint(arena, "standard_library_default={s}", .{self.host_libdir}),
            "-launch-method",
            self.launch_method,
            "-runtime-search",
            self.runtime_search,
        });
    }
    try argv.appendSlice(arena, extra_flags);
    try argv.appendSlice(arena, &.{
        "-o",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, exe_rel }),
    });
    for (objs) |obj_rel| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, obj_rel }));
    }
    try runChecked(io, gpa, argv.items);
}

fn appendBaseOcamlc(self: *Self, arena: std.mem.Allocator, argv: *std.ArrayList([]const u8)) !void {
    try argv.appendSlice(arena, &.{
        self.ocamlrun.path(),
        self.boot_ocamlc.path(),
        "-nostdlib",
        "-I",
        self.stdlib_dir.path(),
        "-use-prims",
        self.primitives.path(),
    });
}

fn fileExistsInDir(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    if (dir.openFile(io, sub_path, .{})) |f| {
        f.close(io);
        return true;
    } else |_| {
        return false;
    }
}

fn runWithStdinCaptureStdout(
    io: std.Io,
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    stdin_bytes: []const u8,
) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_bytes.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    if (stdin_bytes.len > 0) {
        if (child.stdin) |stdin_file| {
            try stdin_file.writeStreamingAll(io, stdin_bytes);
            stdin_file.close(io);
            child.stdin = null;
        }
    }

    var stdout_reader = child.stdout.?.reader(io, &.{});
    const stdout_data = try stdout_reader.interface.allocRemaining(gpa, .unlimited);
    errdefer gpa.free(stdout_data);

    var stderr_reader = child.stderr.?.reader(io, &.{});
    const stderr_data = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(stderr_data);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code == 0) return stdout_data,
        else => {},
    }

    const joined = try std.mem.join(gpa, " ", argv);
    defer gpa.free(joined);
    std.log.err("Command failed: {s}\nstderr:\n{s}", .{ joined, stderr_data });
    return error.SubprocessFailed;
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
