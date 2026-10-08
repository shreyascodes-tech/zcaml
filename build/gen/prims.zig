//! Replacement for `runtime/gen_primitives.sh`, `runtime/gen_primsc.sh` and the
//! two `sed` recipes in the Makefile that derive headers from
//! `runtime/caml/instruct.h`.

const std = @import("std");
const Writer = std.Io.Writer;

/// `CAMLprim value ` — the prefix `gen_primitives.sh` matches at line start.
const prim_prefix = "CAMLprim value ";

const ScanError = error{OutOfMemory};

/// Collects primitive names and `CAMLextern` declarations from one `.c` file.
///
/// `gen_primitives.sh` matches `^CAMLprim value \([a-z][a-z0-9_]*\)`, i.e. it
/// ignores preprocessor conditionals entirely: a primitive guarded by
/// `#ifdef HAS_ZSTD` is listed whether or not the macro is set, because the
/// `#else` branch always provides a stub. `gen_primsc.sh` matches the same
/// lines but keeps the parameter list, continuing onto following lines until it
/// finds a `)`.
pub const Scanner = struct {
    /// Primitive names, in file order. Sorted and deduplicated by `finish`.
    /// These borrow from the sources passed to `scan`, which must outlive the
    /// scanner.
    names: std.ArrayList([]const u8) = .empty,
    /// `CAMLextern` declarations, in file order, newline-terminated. Owned.
    decls: std.ArrayList(u8) = .empty,

    pub fn deinit(s: *Scanner, gpa: std.mem.Allocator) void {
        s.names.deinit(gpa);
        s.decls.deinit(gpa);
    }

    pub fn scan(s: *Scanner, gpa: std.mem.Allocator, source: []const u8) ScanError!void {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, prim_prefix)) continue;

            const rest = line[prim_prefix.len..];
            const name = scanName(rest) orelse continue;
            try s.names.append(gpa, name);

            // `s/^CAMLprim /CAMLextern /` then `s/).*$/);/`: the declaration
            // ends at the first `)` on this line, or on a following one.
            try s.decls.appendSlice(gpa, "CAMLextern value ");
            if (std.mem.indexOfScalar(u8, rest, ')')) |close| {
                try s.decls.appendSlice(gpa, rest[0..close]);
            } else {
                try s.decls.appendSlice(gpa, rest);
                while (lines.next()) |cont_raw| {
                    const cont = std.mem.trimEnd(u8, cont_raw, "\r");
                    try s.decls.append(gpa, '\n');
                    if (std.mem.indexOfScalar(u8, cont, ')')) |close| {
                        try s.decls.appendSlice(gpa, cont[0..close]);
                        break;
                    }
                    try s.decls.appendSlice(gpa, cont);
                }
            }
            try s.decls.appendSlice(gpa, ");\n");
        }
    }

    /// Sorts bytewise (the scripts force `LC_ALL=C`) and removes duplicates,
    /// which the shell version does with `sort | uniq` to keep the bytecode
    /// interpreter's primitive table consistent.
    pub fn finish(s: *Scanner) []const []const u8 {
        std.mem.sort([]const u8, s.names.items, {}, lessThan);
        var n: usize = 0;
        for (s.names.items) |name| {
            if (n > 0 and std.mem.eql(u8, s.names.items[n - 1], name)) continue;
            s.names.items[n] = name;
            n += 1;
        }
        s.names.shrinkRetainingCapacity(n);
        return s.names.items;
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

/// `\([a-z][a-z0-9_]*\)`.
fn scanName(rest: []const u8) ?[]const u8 {
    if (rest.len == 0 or !std.ascii.isLower(rest[0])) return null;
    var end: usize = 1;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') break;
    }
    return rest[0..end];
}

/// The `primitives` file: one name per line. Passed to `ocamlc -use-prims` and
/// read by `lambda/runtimedef.ml`.
pub const Primitives = struct {
    names: []const []const u8,

    pub fn format(p: Primitives, w: *Writer) Writer.Error!void {
        for (p.names) |name| try w.print("{s}\n", .{name});
    }
};

/// `runtime/prims.c`: declarations plus the function-pointer and name tables
/// that `ocamlrun` dispatches through.
pub const PrimsC = struct {
    names: []const []const u8,
    decls: []const u8,

    pub fn format(p: PrimsC, w: *Writer) Writer.Error!void {
        return writePrimsC(w, p.names, p.decls);
    }
};

fn writePrimsC(w: *Writer, names: []const []const u8, decls: []const u8) Writer.Error!void {
    try w.writeAll(
        \\/* Generated file, do not edit */
        \\
        \\#define CAML_INTERNALS
        \\#include "caml/mlvalues.h"
        \\#include "caml/prims.h"
        \\#include "caml/startup.h"
        \\#include "build_config.h"
        \\
        \\
    );
    try w.writeAll(decls);

    try w.writeAll("\nconst c_primitive caml_builtin_cprim[] = {\n");
    for (names) |name| try w.print("  (c_primitive) {s},\n", .{name});
    try w.writeAll("  0 };\n");

    try w.writeAll("\nconst char * const caml_names_of_builtin_cprim[] = {\n");
    for (names) |name| try w.print("  \"{s}\",\n", .{name});
    try w.writeAll("  0 };\n");

    // ocamlrun supports every launch mechanism, and resolves the stdlib
    // through the directory baked into build_config.h.
    try w.writeAll(
        \\
        \\const enum caml_byte_program_mode caml_byte_program_mode = STANDARD;
        \\const char_os *caml_runtime_standard_library_default = OCAML_STDLIB_DIR;
        \\
    );
}

/// Both headers below are `#include`d in the middle of an array initialiser,
/// so they cannot carry a provenance comment, and their output is kept
/// byte-identical to what the Makefile's `sed` recipes produce so that a plain
/// `diff` against a reference build verifies them.
///
/// Note the two are *not* symmetrical: `jumptbl.h` only transforms indented
/// lines, which excludes the unindented `FIRST_UNIMPLEMENTED_OP` terminator
/// (`interp.c` has no label for it), so the jump table has one entry fewer
/// than the name table.
fn eachLine(header: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, header, '\n');
}

/// `runtime/caml/opnames.h`: instruction names, used by the debug runtime's
/// bytecode tracer.
pub const Opnames = struct {
    header: []const u8,

    pub fn format(o: Opnames, w: *Writer) Writer.Error!void {
        return writeOpnames(w, o.header);
    }
};

/// `runtime/caml/jumptbl.h`: the computed-goto label table `interp.c` uses
/// when `THREADED_CODE` is defined.
pub const Jumptbl = struct {
    header: []const u8,

    pub fn format(j: Jumptbl, w: *Writer) Writer.Error!void {
        return writeJumptbl(w, j.header);
    }
};

/// Reproduces:
///     tr -d '\r' | sed -e '/\/\*/d' -e '/^#/d' \
///                      -e 's/enum /static char const * const names_of_/' \
///                      -e 's/{$/[] = {/' \
///                      -e 's/\([[:upper:]][[:upper:]_0-9]*\)/"\1"/g'
fn writeOpnames(w: *Writer, header: []const u8) Writer.Error!void {
    var lines = eachLine(header);
    var first = true;
    while (lines.next()) |raw| {
        const line = stripCr(raw);
        // Whole-line deletions: any line mentioning a comment, and all
        // preprocessor directives.
        if (std.mem.indexOf(u8, line, "/*") != null) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (!first) try w.writeByte('\n');
        first = false;

        var rest = line;
        if (std.mem.indexOf(u8, rest, "enum ")) |i| {
            try w.writeAll(rest[0..i]);
            try w.writeAll("static char const * const names_of_");
            rest = rest[i + "enum ".len ..];
        }
        const body = if (std.mem.endsWith(u8, rest, "{")) rest[0 .. rest.len - 1] else rest;
        try quoteIdents(w, body);
        if (body.len != rest.len) try w.writeAll("[] = {");
    }
}

/// Wraps each `[[:upper:]][[:upper:]_0-9]*` run in double quotes, passing
/// everything else through unchanged.
fn quoteIdents(w: *Writer, line: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        if (!std.ascii.isUpper(line[i])) {
            try w.writeByte(line[i]);
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < line.len) : (end += 1) {
            const c = line[end];
            if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c) and c != '_') break;
        }
        try w.print("\"{s}\"", .{line[i..end]});
        i = end;
    }
}

/// Reproduces:
///     tr -d '\r' | sed -n -e '/^  /s/ \([A-Z]\)/ \&\&lbl_\1/gp' -e '/^}/q'
fn writeJumptbl(w: *Writer, header: []const u8) Writer.Error!void {
    var lines = eachLine(header);
    while (lines.next()) |raw| {
        const line = stripCr(raw);
        if (std.mem.startsWith(u8, line, "}")) break;
        if (!std.mem.startsWith(u8, line, "  ")) continue;

        // `s/ \([A-Z]\)/ &&lbl_\1/g`: only an identifier preceded by a space
        // is rewritten, and only the matched space is consumed. That is why
        // runs of several spaces in the source survive in the output.
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            try w.writeByte(line[i]);
            if (line[i] != ' ') continue;
            if (i + 1 < line.len and std.ascii.isUpper(line[i + 1])) {
                try w.writeAll("&&lbl_");
            }
        }
        try w.writeByte('\n');
    }
}

fn stripCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

test "scan finds single and multi-line primitives" {
    const gpa = std.testing.allocator;
    var s: Scanner = .{};
    defer s.deinit(gpa);

    try s.scan(gpa,
        \\CAMLprim value caml_zzz(value x)
        \\{ return x; }
        \\static value helper(value x);
        \\CAMLprim value caml_aaa(value a1, value ofs1,
        \\                        value a2, value ofs2)
        \\{
        \\CAMLprim uint64_t caml_lxm_next_unboxed(value v)
        \\CAMLprim value Caml_bogus(value v)
        \\
    );

    try std.testing.expectEqualStrings(
        \\CAMLextern value caml_zzz(value x);
        \\CAMLextern value caml_aaa(value a1, value ofs1,
        \\                        value a2, value ofs2);
        \\
    , s.decls.items);

    // Sorted, and neither the non-`value` return type nor the capitalised
    // name is a primitive.
    const names = s.finish();
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("caml_aaa", names[0]);
    try std.testing.expectEqualStrings("caml_zzz", names[1]);
}

test "scan deduplicates names across #ifdef branches" {
    const gpa = std.testing.allocator;
    var s: Scanner = .{};
    defer s.deinit(gpa);

    try s.scan(gpa,
        \\#ifdef HAS_ZSTD
        \\CAMLprim value caml_zstd_initialize(value vunit)
        \\#else
        \\CAMLprim value caml_zstd_initialize(value vunit)
        \\#endif
        \\
    );

    const names = s.finish();
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("caml_zstd_initialize", names[0]);
}

/// The shape that matters: two spaces after `BNEQ,` in the real header, an
/// unindented terminator, and a comment line.
const test_header =
    "/* The instruction set. */\r\n" ++
    "#ifdef CAML_INTERNALS\n" ++
    "\n" ++
    "enum instructions {\n" ++
    "  ACC0, ACC1,\n" ++
    "  BEQ, BNEQ,  BLTINT,\n" ++
    "FIRST_UNIMPLEMENTED_OP};\n" ++
    "\n" ++
    "#endif\n";

test "opnames quotes every instruction, including the terminator" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeOpnames(&w, test_header);
    try std.testing.expectEqualStrings(
        // The deleted comment and `#ifdef` leave nothing behind; the blank
        // line between them and the enum survives.
        "\n" ++
            "static char const * const names_of_instructions [] = {\n" ++
            "  \"ACC0\", \"ACC1\",\n" ++
            "  \"BEQ\", \"BNEQ\",  \"BLTINT\",\n" ++
            "\"FIRST_UNIMPLEMENTED_OP\"};\n" ++
            "\n",
        w.buffered(),
    );
}

test "jumptbl skips the unindented terminator and keeps double spaces" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeJumptbl(&w, test_header);
    try std.testing.expectEqualStrings(
        "  &&lbl_ACC0, &&lbl_ACC1,\n" ++
            "  &&lbl_BEQ, &&lbl_BNEQ,  &&lbl_BLTINT,\n",
        w.buffered(),
    );
}
