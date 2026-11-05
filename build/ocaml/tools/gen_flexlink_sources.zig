//! Generated and patched flexlink sources (what flexdll's Makefile would
//! produce), set up to use `zig cc` as the mingw C toolchain.
const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const InputDir = utils.InputDir;
const OutputFile = utils.OutputFile;
const replaceOnce = utils.replaceOnce;

flexdll_src_dir: InputDir,
zig_toolchain_ml: InputFile,
version_ml: OutputFile,
compat_ml: OutputFile,
coff_ml: OutputFile,
reloc_ml: OutputFile,

const GenFlexlinkSources = @This();

pub fn run(self: *GenFlexlinkSources, init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var root = try self.flexdll_src_dir.open(io, .{});
    defer root.close(io);

    const opam = try root.readFileAlloc(io, "flexdll.opam", arena, .unlimited);
    const version = blk: {
        var lines = std.mem.splitScalar(u8, opam, '\n');
        while (lines.next()) |line| {
            const rest = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, rest, "version:")) continue;
            const q1 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const q2 = std.mem.indexOfScalarPos(u8, rest, q1 + 1, '"') orelse continue;
            break :blk rest[q1 + 1 .. q2];
        }
        return error.FlexdllVersionNotFound;
    };
    try self.version_ml.writeAll(io, try std.fmt.allocPrint(arena,
        \\let version = "{s}"
        \\let mingw_prefix = "i686-w64-mingw32-"
        \\let mingw64_prefix = "x86_64-w64-mingw32-"
        \\let msvc = "cl.exe"
        \\let msvc64 = "cl.exe"
        \\let cygwin64 = "x86_64-pc-cygwin-gcc"
        \\let mingw = "zig cc -target x86-windows-gnu -fno-sanitize=undefined"
        \\let mingw64 = "zig cc -target x86_64-windows-gnu -fno-sanitize=undefined"
        \\let gnat = "gcc"
        \\
    , .{version}));

    // Compat.ml: every shim is unnecessary on OCaml >= 4.08; drop those
    // lines and strip the `NNN:` prefixes from the rest.
    const compat_in = try root.readFileAlloc(io, "Compat.ml.in", arena, .unlimited);
    var compat: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, compat_in, '\n');
    while (lines.next()) |line| {
        var digits: usize = 0;
        while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
        if (digits > 0 and digits < line.len and line[digits] == ':') {
            const level = try std.fmt.parseInt(u32, line[0..digits], 10);
            if (level <= 408) continue;
            try compat.appendSlice(arena, line[digits + 1 ..]);
        } else {
            try compat.appendSlice(arena, line);
        }
        if (lines.peek() != null) try compat.append(arena, '\n');
    }
    try self.compat_ml.writeAll(io, compat.items);

    // coff.ml: flexlink keeps relocations in reverse order, but lld-link expects
    // them sorted by address when it groups base relocations into pages (it
    // would emit corrupt `.reloc` blocks, so rebased DLLs keep stale pointers).
    var coff: []const u8 = try root.readFileAlloc(io, "coff.ml", arena, .unlimited);
    coff = try replaceOnce(arena, coff,
        \\            List.iter (Reloc.put oc) x.relocs
        \\
    ,
        \\            List.iter (Reloc.put oc)
        \\              (List.stable_sort (fun r1 r2 -> Int32.compare r1.addr r2.addr) x.relocs)
        \\
    );
    try self.coff_ml.writeAll(io, coff);

    const zig_toolchain = try self.zig_toolchain_ml.readAll(io, arena);
    var reloc: []const u8 = try root.readFileAlloc(io, "reloc.ml", arena, .unlimited);
    for (reloc_patches) |patch| {
        reloc = try replaceOnce(arena, reloc, patch[0], patch[1]);
    }
    reloc = try replaceOnce(arena, reloc, "let setup_toolchain () =\n", try std.mem.concat(arena, u8, &.{
        "(* zcaml: zig cc support, from build/ocaml/flexdll/zig_toolchain.ml *)\n",
        zig_toolchain,
        "\nlet setup_toolchain () =\n",
    }));
    try self.reloc_ml.writeAll(io, reloc);
}

const reloc_patches = [_][2][]const u8{
    .{
        \\let find_file fn =
        \\  try find_file_exn fn
        \\  with Not_found ->
        \\    failwith (Printf.sprintf "Cannot find file %S" fn)
        ,
        \\(* zcaml: `-l` libraries resolved by `zig cc` itself (see zig_setup). *)
        \\let zig_libs : (string, unit) Hashtbl.t = Hashtbl.create 8
        \\
        \\let find_file fn =
        \\  try find_file_exn fn
        \\  with Not_found ->
        \\    if Hashtbl.mem zig_libs fn then fn
        \\    else failwith (Printf.sprintf "Cannot find file %S" fn)
    },
    .{
        \\    if Lib.is_dll fn then `Lib ([], dll_exports fn)
        ,
        \\    if Hashtbl.mem zig_libs fn then `Lib ([], [])
        \\    else if Lib.is_dll fn then `Lib ([], dll_exports fn)
    },
    // Backport of flexdll GPR#169: drop `.llvm_addrsig` (emitted by clang) from
    // rewritten objects, its symbol indices become stale.
    .{
        \\  let close_obj name imps obj =
        \\    error_imports name imps;
        \\    add_reloc name obj imps;
        \\    record_obj obj
        ,
        \\  let drop_addrsig obj =
        \\    let addrsig s = s.sec_name = ".llvm_addrsig" in
        \\    obj.sections <- List.filter (fun s -> not (addrsig s)) obj.sections;
        \\    obj.symbols <-
        \\      List.filter
        \\        (fun s ->
        \\           match s.section with
        \\           | `Section sec -> not (addrsig sec)
        \\           | `Num _ -> true)
        \\        obj.symbols
        \\  in
        \\
        \\  let close_obj name imps obj =
        \\    error_imports name imps;
        \\    add_reloc name obj imps;
        \\    drop_addrsig obj;
        \\    record_obj obj
    },
    // `zig cc` only understands the `-Wl,--entry=` spelling, and would otherwise
    // write an import library next to the first object file. `-I` is useless when
    // linking, and the `-L` directories (only used for `-l` libraries left to
    // `zig cc`) go in a response file when long: on Windows, commands longer than
    // cmd.exe's limit would otherwise be run with bash.
    .{
        \\          (if main_pgm then "" else if !noentry then "-Wl,-e0 " else if !machine = `x86 then "-Wl,-e_FlexDLLiniter@12 " else "-Wl,-eFlexDLLiniter ")
        \\          (mk_dirs_opt "-I")
        \\          (mk_dirs_opt "-L")
        \\          (Filename.quote output_file)
        \\          descr
        \\          files
        \\          def_file
        \\          (if !implib then "-Wl,--out-implib=" ^ Filename.quote (Filename.chop_extension output_file ^ ".a") else "")
        ,
        \\          (if main_pgm then "" else if !noentry then "-Wl,-e0 " else if !machine = `x86 then "-Wl,--entry=_FlexDLLiniter@12 " else "-Wl,--entry=FlexDLLiniter ")
        \\          ""
        \\          (quote_files (List.map (fun d -> "-L" ^ d) !dirs))
        \\          (Filename.quote output_file)
        \\          descr
        \\          files
        \\          def_file
        \\          (if !implib then "-Wl,--out-implib=" ^ Filename.quote (Filename.chop_extension output_file ^ ".a")
        \\           else if link_exe = `EXE then ""
        \\           else "-Wl,--out-implib=" ^ Filename.quote (temp_file "dyndll_implib" ".lib"))
    },
    // Don't require bash on Unix hosts (e.g. Alpine): the command is plain sh.
    .{
        \\    let invoke = Printf.sprintf "bash %s" fn in
        ,
        \\    let invoke = Printf.sprintf "%s %s" (if Sys.unix then "sh" else "bash") fn in
    },
    // Find the default libraries with `zig cc -v` instead of `gcc -print-search-dirs`.
    .{
        \\  | `MINGW ->
        \\      mingw_libs Version.mingw_prefix
        \\  | `MINGW64 ->
        \\      mingw_libs Version.mingw64_prefix
        ,
        \\  | `MINGW | `MINGW64 ->
        \\      ignore mingw_libs;
        \\      zig_setup ()
    },
};
