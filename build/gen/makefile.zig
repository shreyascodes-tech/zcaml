//! Just enough GNU make to evaluate the `*_SOURCES` lists in OCaml's
//! Makefiles. Variables are stored unexpanded (make's `=` is lazy) and
//! expanded on demand, so an unsupported construct only fails when something
//! asks for it. Conditionals are not evaluated: every list we read is defined
//! at top level, and the configure-provided variables they reference are
//! seeded by the caller.
//!
//! Anything outside the supported subset is `error.Unsupported`, so a new
//! OCaml release breaks `zig build gen` loudly rather than dropping files.

const std = @import("std");

const Vars = @This();

arena: std.mem.Allocator,
/// Name → unexpanded right-hand side, in definition order.
defs: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

pub const Error = error{ OutOfMemory, Unsupported, Undefined };

/// The function or variable name at fault.
pub const Diagnostic = struct { name: []const u8 = "" };

pub fn seed(v: *Vars, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    try v.defs.put(v.arena, name, value);
}

/// Collects variable assignments; rules, recipes, directives and conditionals
/// are ignored (conditional bodies are still scanned).
pub fn parse(v: *Vars, text: []const u8) error{OutOfMemory}!void {
    var lines = Lines{ .text = text };
    while (try lines.next(v.arena)) |line| {
        if (line.len == 0 or line[0] == '\t' or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "define ")) {
            while (try lines.next(v.arena)) |l| if (std.mem.startsWith(u8, l, "endef")) break;
            continue;
        }
        const assign = Assignment.parse(line) orelse continue;
        switch (assign.op) {
            .set, .immediate => try v.defs.put(v.arena, assign.name, assign.value),
            .default => if (!v.defs.contains(assign.name)) try v.defs.put(v.arena, assign.name, assign.value),
            .append => {
                const gop = try v.defs.getOrPut(v.arena, assign.name);
                gop.value_ptr.* = if (gop.found_existing)
                    try std.mem.join(v.arena, " ", &.{ gop.value_ptr.*, assign.value })
                else
                    assign.value;
            },
        }
    }
}

pub fn words(v: *Vars, name: []const u8, diag: *Diagnostic) Error![]const []const u8 {
    const raw = v.defs.get(name) orelse {
        diag.name = name;
        return error.Undefined;
    };
    const expanded = try v.expand(raw, diag);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, expanded, " \t");
    while (it.next()) |w| try out.append(v.arena, w);
    return out.toOwnedSlice(v.arena);
}

fn expand(v: *Vars, text: []const u8, diag: *Diagnostic) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '$') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '$') {
            try out.append(v.arena, text[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= text.len) return unsupported(diag, "$");
        switch (text[i + 1]) {
            '$' => {
                try out.append(v.arena, '$');
                i += 2;
            },
            '(' => {
                const close = matchParen(text, i + 1) orelse return unsupported(diag, text[i..]);
                try out.appendSlice(v.arena, try v.expandRef(text[i + 2 .. close], diag));
                i = close + 1;
            },
            else => {
                try out.appendSlice(v.arena, try v.lookup(text[i + 1 .. i + 2], diag));
                i += 2;
            },
        }
    }
    return out.items;
}

fn expandRef(v: *Vars, body: []const u8, diag: *Diagnostic) Error![]const u8 {
    // `$(fn args)` has whitespace after the name; `$(VAR)`/`$(VAR:a=b)` never do.
    const name_end = std.mem.indexOfAny(u8, body, " \t:") orelse body.len;
    const name = body[0..name_end];
    if (name_end < body.len and (body[name_end] == ' ' or body[name_end] == '\t')) {
        return v.call(name, std.mem.trimStart(u8, body[name_end..], " \t"), diag);
    }
    if (name_end < body.len) {
        const subst = body[name_end + 1 ..];
        const eq = std.mem.indexOfScalar(u8, subst, '=') orelse return unsupported(diag, body);
        return v.patsubst(subst[0..eq], subst[eq + 1 ..], try v.lookup(name, diag), .suffix_implicit);
    }
    return v.lookup(name, diag);
}

fn lookup(v: *Vars, name: []const u8, diag: *Diagnostic) Error![]const u8 {
    const raw = v.defs.get(name) orelse {
        diag.name = name;
        return error.Undefined;
    };
    return v.expand(raw, diag);
}

fn call(v: *Vars, name: []const u8, args_text: []const u8, diag: *Diagnostic) Error![]const u8 {
    const Fn = enum { addprefix, addsuffix, filter, @"filter-out", strip, subst, patsubst };
    const f = std.meta.stringToEnum(Fn, name) orelse return unsupported(diag, name);
    var args = splitArgs(args_text);
    switch (f) {
        .addprefix, .addsuffix => {
            const affix = try v.expand(args.next() orelse "", diag);
            const list = try v.expand(args.next() orelse "", diag);
            var out: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, list, " \t");
            while (it.next()) |w| {
                if (out.items.len != 0) try out.append(v.arena, ' ');
                if (f == .addprefix) try out.appendSlice(v.arena, affix);
                try out.appendSlice(v.arena, w);
                if (f == .addsuffix) try out.appendSlice(v.arena, affix);
            }
            return out.items;
        },
        .filter, .@"filter-out" => {
            const patterns = try v.expand(args.next() orelse "", diag);
            const list = try v.expand(args.next() orelse "", diag);
            var out: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, list, " \t");
            while (it.next()) |w| {
                var matched = false;
                var pit = std.mem.tokenizeAny(u8, patterns, " \t");
                while (pit.next()) |p| {
                    if (matchPattern(p, w) != null) matched = true;
                }
                if (matched != (f == .filter)) continue;
                if (out.items.len != 0) try out.append(v.arena, ' ');
                try out.appendSlice(v.arena, w);
            }
            return out.items;
        },
        .strip => {
            const list = try v.expand(args.next() orelse "", diag);
            var out: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, list, " \t");
            while (it.next()) |w| {
                if (out.items.len != 0) try out.append(v.arena, ' ');
                try out.appendSlice(v.arena, w);
            }
            return out.items;
        },
        .subst => {
            const from = try v.expand(args.next() orelse "", diag);
            const to = try v.expand(args.next() orelse "", diag);
            const text = try v.expand(args.next() orelse "", diag);
            return std.mem.replaceOwned(u8, v.arena, text, from, to);
        },
        .patsubst => {
            const from = try v.expand(args.next() orelse "", diag);
            const to = try v.expand(args.next() orelse "", diag);
            const text = try v.expand(args.next() orelse "", diag);
            return v.patsubst(from, to, text, .explicit);
        },
    }
}

const PatMode = enum {
    /// `$(patsubst ...)`: patterns without `%` match whole words only.
    explicit,
    /// `$(VAR:a=b)`: patterns without `%` are suffixes, as if `%a=%b`.
    suffix_implicit,
};

fn patsubst(v: *Vars, from: []const u8, to: []const u8, text: []const u8, mode: PatMode) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |w| {
        if (out.items.len != 0) try out.append(v.arena, ' ');
        const has_percent = std.mem.indexOfScalar(u8, from, '%') != null;
        if (mode == .suffix_implicit and !has_percent) {
            if (std.mem.endsWith(u8, w, from)) {
                try out.appendSlice(v.arena, w[0 .. w.len - from.len]);
                try out.appendSlice(v.arena, to);
            } else try out.appendSlice(v.arena, w);
            continue;
        }
        if (matchPattern(from, w)) |stem| {
            try out.appendSlice(v.arena, try std.mem.replaceOwned(u8, v.arena, to, "%", stem));
        } else try out.appendSlice(v.arena, w);
    }
    return out.items;
}

/// Returns the stem matched by `%`; without `%` the match is exact and the
/// stem empty.
fn matchPattern(pattern: []const u8, word: []const u8) ?[]const u8 {
    const pct = std.mem.indexOfScalar(u8, pattern, '%') orelse
        return if (std.mem.eql(u8, pattern, word)) "" else null;
    const prefix = pattern[0..pct];
    const suffix = pattern[pct + 1 ..];
    if (word.len < prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, word, prefix) or !std.mem.endsWith(u8, word, suffix)) return null;
    return word[prefix.len .. word.len - suffix.len];
}

fn splitArgs(text: []const u8) ArgIterator {
    return .{ .text = text };
}

const ArgIterator = struct {
    text: []const u8,
    i: usize = 0,

    fn next(it: *ArgIterator) ?[]const u8 {
        if (it.i > it.text.len) return null;
        var depth: usize = 0;
        var j = it.i;
        while (j < it.text.len) : (j += 1) switch (it.text[j]) {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' => if (depth == 0) break,
            else => {},
        };
        const arg = it.text[it.i..j];
        it.i = j + 1;
        return arg;
    }
};

fn matchParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

fn unsupported(diag: *Diagnostic, what: []const u8) Error {
    diag.name = what;
    return error.Unsupported;
}

const Assignment = struct {
    name: []const u8,
    op: enum { set, immediate, default, append },
    value: []const u8,

    fn parse(line: []const u8) ?Assignment {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        var name_end = eq;
        const op: @FieldType(Assignment, "op") = if (eq > 0 and line[eq - 1] == ':') blk: {
            name_end -= 1;
            break :blk .immediate;
        } else if (eq > 0 and line[eq - 1] == '+') blk: {
            name_end -= 1;
            break :blk .append;
        } else if (eq > 0 and line[eq - 1] == '?') blk: {
            name_end -= 1;
            break :blk .default;
        } else .set;
        const name = std.mem.trim(u8, line[0..name_end], " \t");
        if (name.len == 0) return null;
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return null;
        return .{ .name = name, .op = op, .value = std.mem.trim(u8, line[eq + 1 ..], " \t") };
    }
};

/// Logical lines: continuations joined, comments stripped, leading tab kept.
const Lines = struct {
    text: []const u8,
    i: usize = 0,

    fn next(l: *Lines, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        if (l.i >= l.text.len) return null;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, l.text, l.i, '\n') orelse l.text.len;
            var line = l.text[l.i..nl];
            l.i = @min(nl + 1, l.text.len);
            line = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];
            const continued = std.mem.endsWith(u8, line, "\\");
            if (continued) line = line[0 .. line.len - 1];
            if (out.items.len != 0) {
                try out.append(arena, ' ');
                line = std.mem.trimStart(u8, line, " \t");
            }
            try out.appendSlice(arena, std.mem.trimEnd(u8, line, " \t"));
            if (!continued or l.i >= l.text.len) break;
        }
        return out.items;
    }
};
