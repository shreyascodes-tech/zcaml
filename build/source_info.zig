const std = @import("std");

pub const OcamlVersionInfo = struct {
    sem_ver: std.SemanticVersion,
    dev_version: bool,
    major: u32,
    minor: u32,
    patchlevel: u32,
    release_number: ?u32,
    extra: []const u8,
    extra_prefix: []const u8,
    version_string: []const u8,
    version_number: u32,
    magic_prefix: ?[]const u8,
    magic_version: ?[]const u8,
    exec_format: ?[]const u8,
    exec_magic_length: ?usize,
};

pub const SourceInfo = struct {
    b: *std.Build,
    dep: *std.Build.Dependency,
    version: OcamlVersionInfo,
    version_m4: []const u8,
    makefile_src: []const u8,

    pub fn load(b: *std.Build, ocaml_dep: *std.Build.Dependency) SourceInfo {
        const version_m4 = readFile(b, ocaml_dep, "build-aux/ocaml_version.m4");
        const version_file = readFile(b, ocaml_dep, "VERSION");
        const makefile_src = readFile(b, ocaml_dep, "Makefile");

        const version = parseOcamlVersion(b, version_m4, version_file);

        return .{
            .b = b,
            .dep = ocaml_dep,
            .version = version,
            .version_m4 = version_m4,
            .makefile_src = makefile_src,
        };
    }

    pub fn magicNumber(self: SourceInfo, kind: []const u8) []const u8 {
        const prefix = self.version.magic_prefix orelse @panic("magicNumber called on OCaml version without MAGIC_NUMBER__PREFIX");
        const ver = self.version.magic_version orelse @panic("magicNumber called on OCaml version without MAGIC_NUMBER__VERSION");

        var lines = std.mem.splitScalar(u8, self.version_m4, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "DEFINE_MAGIC_NUMBER([")) {
                const inner = line["DEFINE_MAGIC_NUMBER([".len..];
                const k_end = std.mem.indexOfScalar(u8, inner, ']') orelse continue;
                const k = inner[0..k_end];
                if (!std.mem.eql(u8, k, kind)) continue;
                const rest = std.mem.trim(u8, inner[k_end + 1 ..], " \t,");
                if (std.mem.startsWith(u8, rest, "[")) {
                    const c_end = std.mem.indexOfScalar(u8, rest[1..], ']') orelse continue;
                    const fmt_char = rest[1 .. 1 + c_end];
                    return self.b.fmt("{s}{s}{s}", .{ prefix, fmt_char, ver });
                } else if (std.mem.startsWith(u8, rest, "EXEC__FORMAT")) {
                    const fmt_char = self.version.exec_format.?;
                    return self.b.fmt("{s}{s}{s}", .{ prefix, fmt_char, ver });
                }
            }
        }
        std.debug.panic("m4 safety check failed: DEFINE_MAGIC_NUMBER([{s}], ...) not found in build-aux/ocaml_version.m4", .{kind});
    }

    pub fn readFile(b: *std.Build, ocaml_dep: *std.Build.Dependency, sub_path: []const u8) []const u8 {
        const dir = ocaml_dep.builder.build_root.handle;
        return dir.readFileAlloc(b.graph.io, sub_path, b.allocator, .unlimited) catch |err| {
            std.debug.panic("Failed to read '{s}' from OCaml source dependency: {t}", .{ sub_path, err });
        };
    }

    pub const VarExpansion = struct {
        name: []const u8,
        values: []const []const u8,
    };

    /// Parses a variable assignment `var_name = ...` (with `\` line continuations,
    /// `+=` appends, `ifeq` blocks, and nested `$(addprefix ...)` / `$(addsuffix ...)` / `$(VAR)`)
    /// from the root OCaml Makefile.
    /// Panics if the variable is missing, empty, or contains unknown `$(...)` expansions.
    pub fn parseMakefileList(
        self: SourceInfo,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) []const []const u8 {
        return self.parseMakefileListFromSource("Makefile", self.makefile_src, var_name, expansions);
    }

    pub fn parseMakefileListOptional(
        self: SourceInfo,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) ?[]const []const u8 {
        return self.parseMakefileListFromSourceOptional("Makefile", self.makefile_src, var_name, expansions, false);
    }

    /// Parses a variable assignment `var_name = ...` from `sub_path` in the OCaml tarball.
    pub fn parseMakefileListFromFile(
        self: SourceInfo,
        sub_path: []const u8,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) []const []const u8 {
        const src = readFile(self.b, self.dep, sub_path);
        return self.parseMakefileListFromSource(sub_path, src, var_name, expansions);
    }

    pub fn parseMakefileListFromSource(
        self: SourceInfo,
        file_label: []const u8,
        src: []const u8,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) []const []const u8 {
        const items = self.parseMakefileListFromSourceOptional(file_label, src, var_name, expansions, false) orelse {
            std.debug.panic(
                "Makefile safety check failed: variable '{s}' not found in '{s}'",
                .{ var_name, file_label },
            );
        };
        if (items.len == 0) {
            std.debug.panic("Makefile safety check failed: variable '{s}' in '{s}' resolved to 0 items", .{ var_name, file_label });
        }
        return items;
    }

    pub fn parseMakefileListFromSourceAllowEmpty(
        self: SourceInfo,
        file_label: []const u8,
        src: []const u8,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) []const []const u8 {
        return self.parseMakefileListFromSourceOptional(file_label, src, var_name, expansions, true) orelse {
            std.debug.panic(
                "Makefile safety check failed: variable '{s}' not found in '{s}'",
                .{ var_name, file_label },
            );
        };
    }

    pub fn parseMakefileListFromSourceOptional(
        self: SourceInfo,
        file_label: []const u8,
        src: []const u8,
        var_name: []const u8,
        expansions: []const VarExpansion,
        allow_empty: bool,
    ) ?[]const []const u8 {
        _ = allow_empty;
        const alloc = self.b.allocator;
        var lines = std.mem.splitScalar(u8, src, '\n');

        var found = false;
        var raw_body: std.ArrayList(u8) = .empty;
        var reading_continuation = false;

        // Track simple 1-level ifeq/ifneq state when condition variables are in `expansions`
        var cond_active = true;
        var in_cond = false;

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (!reading_continuation) {
                const trimmed_line = std.mem.trim(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed_line, "ifeq ") or std.mem.startsWith(u8, trimmed_line, "ifeq(")) {
                    if (evalMakefileIfeq(trimmed_line["ifeq".len..], expansions)) |matched| {
                        in_cond = true;
                        cond_active = matched;
                    }
                    continue;
                } else if (in_cond and std.mem.eql(u8, trimmed_line, "else")) {
                    cond_active = !cond_active;
                    continue;
                } else if (in_cond and (std.mem.eql(u8, trimmed_line, "endif") or std.mem.startsWith(u8, trimmed_line, "endif "))) {
                    in_cond = false;
                    cond_active = true;
                    continue;
                }

                if (!cond_active) continue;

                if (std.mem.startsWith(u8, line, var_name)) {
                    const after = std.mem.trimStart(u8, line[var_name.len..], " \t");
                    const is_assign = std.mem.startsWith(u8, after, "=") and !std.mem.startsWith(u8, after, "==");
                    const is_colon_assign = std.mem.startsWith(u8, after, ":=");
                    const is_plus_assign = std.mem.startsWith(u8, after, "+=");
                    if (is_assign or is_colon_assign or is_plus_assign) {
                        const op_len: usize = if (is_colon_assign or is_plus_assign) 2 else 1;
                        if (!is_plus_assign) {
                            raw_body = .empty;
                        } else if (raw_body.items.len > 0) {
                            raw_body.append(alloc, ' ') catch @panic("OOM");
                        }
                        found = true;
                        const rhs = std.mem.trimStart(u8, after[op_len..], " \t");
                        if (std.mem.endsWith(u8, rhs, "\\")) {
                            raw_body.appendSlice(alloc, rhs[0 .. rhs.len - 1]) catch @panic("OOM");
                            raw_body.append(alloc, ' ') catch @panic("OOM");
                            reading_continuation = true;
                        } else {
                            raw_body.appendSlice(alloc, rhs) catch @panic("OOM");
                        }
                    }
                }
            } else {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (std.mem.endsWith(u8, trimmed, "\\")) {
                    raw_body.appendSlice(alloc, trimmed[0 .. trimmed.len - 1]) catch @panic("OOM");
                    raw_body.append(alloc, ' ') catch @panic("OOM");
                } else {
                    raw_body.appendSlice(alloc, trimmed) catch @panic("OOM");
                    reading_continuation = false;
                }
            }
        }

        if (!found) return null;

        var result: std.ArrayList([]const u8) = .empty;
        self.expandMakefileExprInto(&result, std.mem.trim(u8, raw_body.items, " \t"), "", "", file_label, var_name, expansions);
        return result.items;
    }

    fn expandMakefileExprInto(
        self: SourceInfo,
        out: *std.ArrayList([]const u8),
        expr: []const u8,
        cur_prefix: []const u8,
        cur_suffix: []const u8,
        file_label: []const u8,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) void {
        const alloc = self.b.allocator;
        var i: usize = 0;
        while (i < expr.len) {
            while (i < expr.len and (expr[i] == ' ' or expr[i] == '\t')) : (i += 1) {}
            if (i >= expr.len) break;

            if (std.mem.startsWith(u8, expr[i..], "$(")) {
                const close_idx = findMatchingParen(expr, i + 1) orelse {
                    std.debug.panic("Malformed $(...) in '{s}' variable '{s}'", .{ file_label, var_name });
                };
                const inner = expr[i + 2 .. close_idx];
                i = close_idx + 1;

                if (std.mem.startsWith(u8, inner, "addprefix ")) {
                    const args = inner["addprefix ".len..];
                    const comma_idx = std.mem.indexOfScalar(u8, args, ',') orelse {
                        std.debug.panic("Malformed $(addprefix ...) in '{s}' variable '{s}'", .{ file_label, var_name });
                    };
                    const sub_prefix_raw = std.mem.trim(u8, args[0..comma_idx], " \t");
                    const sub_prefix = self.expandSingleToken(sub_prefix_raw, file_label, var_name, expansions);
                    const sub_body = std.mem.trim(u8, args[comma_idx + 1 ..], " \t");
                    const combined_prefix = if (cur_prefix.len > 0)
                        self.b.fmt("{s}{s}", .{ cur_prefix, sub_prefix })
                    else
                        sub_prefix;
                    self.expandMakefileExprInto(out, sub_body, combined_prefix, cur_suffix, file_label, var_name, expansions);
                } else if (std.mem.startsWith(u8, inner, "addsuffix ")) {
                    const args = inner["addsuffix ".len..];
                    const comma_idx = std.mem.indexOfScalar(u8, args, ',') orelse {
                        std.debug.panic("Malformed $(addsuffix ...) in '{s}' variable '{s}'", .{ file_label, var_name });
                    };
                    const sub_suffix_raw = std.mem.trim(u8, args[0..comma_idx], " \t");
                    const sub_suffix = self.expandSingleToken(sub_suffix_raw, file_label, var_name, expansions);
                    const sub_body = std.mem.trim(u8, args[comma_idx + 1 ..], " \t");
                    const combined_suffix = if (cur_suffix.len > 0)
                        self.b.fmt("{s}{s}", .{ sub_suffix, cur_suffix })
                    else
                        sub_suffix;
                    self.expandMakefileExprInto(out, sub_body, cur_prefix, combined_suffix, file_label, var_name, expansions);
                } else {
                    const ref_name = std.mem.trim(u8, inner, " \t");
                    var expanded = false;
                    for (expansions) |exp| {
                        if (std.mem.eql(u8, exp.name, ref_name)) {
                            for (exp.values) |v| {
                                const item = self.b.fmt("{s}{s}{s}", .{ cur_prefix, v, cur_suffix });
                                out.append(alloc, item) catch @panic("OOM");
                            }
                            expanded = true;
                            break;
                        }
                    }
                    if (!expanded) {
                        std.debug.panic(
                            "Makefile safety check failed: unexpanded variable '$({s})' in '{s}' ('{s}')",
                            .{ ref_name, var_name, file_label },
                        );
                    }
                }
            } else {
                const start = i;
                while (i < expr.len and expr[i] != ' ' and expr[i] != '\t') : (i += 1) {}
                const tok = expr[start..i];
                const expanded_tok = self.expandSingleToken(tok, file_label, var_name, expansions);
                const item = self.b.fmt("{s}{s}{s}", .{ cur_prefix, expanded_tok, cur_suffix });
                out.append(alloc, item) catch @panic("OOM");
            }
        }
    }

    fn expandSingleToken(
        self: SourceInfo,
        tok: []const u8,
        file_label: []const u8,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) []const u8 {
        if (std.mem.indexOfScalar(u8, tok, '$') == null) return tok;
        const alloc = self.b.allocator;
        var res: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < tok.len) {
            if (std.mem.startsWith(u8, tok[i..], "$(")) {
                const close_idx = findMatchingParen(tok, i + 1) orelse {
                    std.debug.panic("Malformed $(...) in token '{s}' ('{s}' in '{s}')", .{ tok, var_name, file_label });
                };
                const ref_name = tok[i + 2 .. close_idx];
                var found_val: ?[]const u8 = null;
                for (expansions) |exp| {
                    if (std.mem.eql(u8, exp.name, ref_name)) {
                        if (exp.values.len != 1) {
                            std.debug.panic("Expected single value for inline expansion '$({s})' in '{s}'", .{ ref_name, tok });
                        }
                        found_val = exp.values[0];
                        break;
                    }
                }
                const v = found_val orelse {
                    std.debug.panic(
                        "Makefile safety check failed: unexpanded inline variable '$({s})' in '{s}' ('{s}')",
                        .{ ref_name, var_name, file_label },
                    );
                };
                res.appendSlice(alloc, v) catch @panic("OOM");
                i = close_idx + 1;
            } else if (tok[i] == '$') {
                std.debug.panic(
                    "Makefile safety check failed: unexpected macro expression '{s}' in '{s}' ('{s}')",
                    .{ tok, var_name, file_label },
                );
            } else {
                res.append(alloc, tok[i]) catch @panic("OOM");
                i += 1;
            }
        }
        return res.items;
    }

    pub const MacroEntry = struct {
        name: []const u8,
        value: ?[]const u8,
        /// Set to true for macros that only exist in some OCaml versions' .h.in templates.
        version_specific: bool = false,
    };

    /// Strictly renders an autoconf `.h.in` file (`runtime/caml/m.h.in`, `s.h.in`, `version.h.in`, `exec.h.in`).
    /// Safety rules:
    /// 1. Every `#undef NAME` or `#define NAME 1` in `.h.in` (excluding header guards and derived macros)
    ///    must exist in `entries`. If the OCaml tarball adds a new macro, this panics with its name.
    /// 2. Every entry in `entries` must appear in the `.h.in` template. If an OCaml version removes
    ///    a macro, this panics telling you which entry is stale.
    pub fn renderConfigHeaderTemplate(
        self: SourceInfo,
        template_sub_path: []const u8,
        entries: []const MacroEntry,
        ignored_defines: []const []const u8,
        extra_footer: []const u8,
    ) []const u8 {
        const alloc = self.b.allocator;
        const template_src = readFile(self.b, self.dep, template_sub_path);

        const used = alloc.alloc(bool, entries.len) catch @panic("OOM");
        @memset(used, false);

        // Verify no duplicate macro names in `entries`
        for (entries, 0..) |e1, i| {
            for (entries[i + 1 ..]) |e2| {
                if (std.mem.eql(u8, e1.name, e2.name)) {
                    std.debug.panic(
                        "Duplicate macro '{s}' in config table for '{s}'",
                        .{ e1.name, template_sub_path },
                    );
                }
            }
        }

        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(alloc, "/* Generated by zcaml from ") catch @panic("OOM");
        out.appendSlice(alloc, template_sub_path) catch @panic("OOM");
        out.appendSlice(alloc, " */\n") catch @panic("OOM");

        var lines = std.mem.splitScalar(u8, template_src, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trimStart(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "#undef ")) {
                const rest = std.mem.trim(u8, trimmed["#undef ".len..], " \t");
                const macro_name = extractMacroIdent(rest);
                const idx = findEntryIndex(entries, macro_name) orelse {
                    std.debug.panic(
                        "Template safety check failed in '{s}': macro '#undef {s}' is not handled in zcaml config table",
                        .{ template_sub_path, macro_name },
                    );
                };
                used[idx] = true;
                if (entries[idx].value) |val| {
                    out.appendSlice(alloc, self.b.fmt("#define {s} {s}\n", .{ macro_name, val })) catch @panic("OOM");
                } else {
                    out.appendSlice(alloc, self.b.fmt("/* #undef {s} */\n", .{macro_name})) catch @panic("OOM");
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "#define ")) {
                const rest = std.mem.trim(u8, trimmed["#define ".len..], " \t");
                const macro_name = extractMacroIdent(rest);
                if (!isIgnoredDefine(macro_name, ignored_defines)) {
                    const idx = findEntryIndex(entries, macro_name) orelse {
                        std.debug.panic(
                            "Template safety check failed in '{s}': macro '#define {s}' is not handled in zcaml config table",
                            .{ template_sub_path, macro_name },
                        );
                    };
                    used[idx] = true;
                    if (entries[idx].value) |val| {
                        out.appendSlice(alloc, self.b.fmt("#define {s} {s}\n", .{ macro_name, val })) catch @panic("OOM");
                    } else {
                        out.appendSlice(alloc, self.b.fmt("/* #undef {s} */\n", .{macro_name})) catch @panic("OOM");
                    }
                    continue;
                }
            }

            out.appendSlice(alloc, line) catch @panic("OOM");
            out.append(alloc, '\n') catch @panic("OOM");
        }

        for (entries, 0..) |entry, idx| {
            if (!used[idx] and !entry.version_specific) {
                std.debug.panic(
                    "Template safety check failed in '{s}': macro '{s}' in zcaml config table does not exist in template",
                    .{ template_sub_path, entry.name },
                );
            }
        }

        if (extra_footer.len > 0) {
            out.appendSlice(alloc, extra_footer) catch @panic("OOM");
        }

        return out.items;
    }

    pub const AtVarEntry = struct {
        name: []const u8,
        value: []const u8,
        version_specific: bool = false,
    };

    /// Strictly renders a template using `@var@` placeholders (such as `stdlib/sys.ml.in`,
    /// `utils/config.generated.ml.in`, `otherlibs/dynlink/dynlink_config.ml.in`, `META.in`).
    /// Panics if any `@var@` in the template is missing from `entries` or if any non-`version_specific` entry is unused.
    pub fn renderAtTemplate(
        self: SourceInfo,
        template_sub_path: []const u8,
        entries: []const AtVarEntry,
    ) []const u8 {
        const alloc = self.b.allocator;
        const template_src = readFile(self.b, self.dep, template_sub_path);

        const used = alloc.alloc(bool, entries.len) catch @panic("OOM");
        @memset(used, false);

        for (entries, 0..) |e1, idx1| {
            for (entries[idx1 + 1 ..]) |e2| {
                if (std.mem.eql(u8, e1.name, e2.name)) {
                    std.debug.panic("Duplicate '@{s}@' in substitution table for '{s}'", .{ e1.name, template_sub_path });
                }
            }
        }

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < template_src.len) {
            if (template_src[i] == '@') {
                if (findClosingAtIdent(template_src, i + 1)) |end_idx| {
                    const var_name = template_src[i + 1 .. end_idx];
                    const entry_idx = findAtVarIndex(entries, var_name) orelse {
                        std.debug.panic(
                            "Template safety check failed in '{s}': placeholder '@{s}@' is not handled in zcaml substitution table",
                            .{ template_sub_path, var_name },
                        );
                    };
                    used[entry_idx] = true;
                    out.appendSlice(alloc, entries[entry_idx].value) catch @panic("OOM");
                    i = end_idx + 1;
                    continue;
                }
            }
            out.append(alloc, template_src[i]) catch @panic("OOM");
            i += 1;
        }

        for (entries, 0..) |entry, idx| {
            if (!used[idx] and !entry.version_specific) {
                std.debug.panic(
                    "Template safety check failed in '{s}': substitution '@{s}@' in zcaml table does not exist in template",
                    .{ template_sub_path, entry.name },
                );
            }
        }

        return out.items;
    }

    /// Strictly renders a template using `%%VAR%%` placeholders (such as `utils/config.mlp` in OCaml 5.0).
    /// Panics if any `%%VAR%%` in the template is missing from `entries` or if any non-`version_specific` entry is unused.
    pub fn renderPercentTemplate(
        self: SourceInfo,
        template_sub_path: []const u8,
        entries: []const AtVarEntry,
    ) []const u8 {
        const alloc = self.b.allocator;
        const template_src = readFile(self.b, self.dep, template_sub_path);

        const used = alloc.alloc(bool, entries.len) catch @panic("OOM");
        @memset(used, false);

        for (entries, 0..) |e1, idx1| {
            for (entries[idx1 + 1 ..]) |e2| {
                if (std.mem.eql(u8, e1.name, e2.name)) {
                    std.debug.panic("Duplicate '%%{s}%%' in substitution table for '{s}'", .{ e1.name, template_sub_path });
                }
            }
        }

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < template_src.len) {
            if (i + 1 < template_src.len and template_src[i] == '%' and template_src[i + 1] == '%') {
                if (findClosingPercentIdent(template_src, i + 2)) |end_idx| {
                    const var_name = template_src[i + 2 .. end_idx];
                    const entry_idx = findAtVarIndex(entries, var_name) orelse {
                        std.debug.panic(
                            "Template safety check failed in '{s}': placeholder '%%{s}%%' is not handled in zcaml substitution table",
                            .{ template_sub_path, var_name },
                        );
                    };
                    used[entry_idx] = true;
                    out.appendSlice(alloc, entries[entry_idx].value) catch @panic("OOM");
                    i = end_idx + 2;
                    continue;
                }
            }
            out.append(alloc, template_src[i]) catch @panic("OOM");
            i += 1;
        }

        for (entries, 0..) |entry, idx| {
            if (!used[idx] and !entry.version_specific) {
                std.debug.panic(
                    "Template safety check failed in '{s}': substitution '%%{s}%%' in zcaml table does not exist in template",
                    .{ template_sub_path, entry.name },
                );
            }
        }

        return out.items;
    }
};

fn findMatchingParen(s: []const u8, open_idx: usize) ?usize {
    std.debug.assert(s[open_idx] == '(');
    var depth: usize = 1;
    var i: usize = open_idx + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '(') {
            depth += 1;
        } else if (s[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn evalMakefileIfeq(rest: []const u8, expansions: []const SourceInfo.VarExpansion) ?bool {
    const trimmed = std.mem.trim(u8, rest, " \t");
    // Format 1: ifeq ($(VAR),val)
    if (std.mem.startsWith(u8, trimmed, "(") and std.mem.endsWith(u8, trimmed, ")")) {
        const inner = trimmed[1 .. trimmed.len - 1];
        const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return null;
        const lhs = std.mem.trim(u8, inner[0..comma], " \t\"'");
        const rhs = std.mem.trim(u8, inner[comma + 1 ..], " \t\"'");
        if (std.mem.startsWith(u8, lhs, "$(") and std.mem.endsWith(u8, lhs, ")")) {
            const var_name = lhs[2 .. lhs.len - 1];
            for (expansions) |exp| {
                if (std.mem.eql(u8, exp.name, var_name) and exp.values.len == 1) {
                    return std.mem.eql(u8, exp.values[0], rhs);
                }
            }
        }
        return null;
    }
    // Format 2: ifeq "$(VAR)" "val"
    if (std.mem.startsWith(u8, trimmed, "\"")) {
        const q1_end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return null;
        const lhs = trimmed[1..q1_end];
        const after_q1 = std.mem.trim(u8, trimmed[q1_end + 1 ..], " \t");
        if (!std.mem.startsWith(u8, after_q1, "\"")) return null;
        const q2_end = std.mem.indexOfScalarPos(u8, after_q1, 1, '"') orelse return null;
        const rhs = after_q1[1..q2_end];
        if (std.mem.startsWith(u8, lhs, "$(") and std.mem.endsWith(u8, lhs, ")")) {
            const var_name = lhs[2 .. lhs.len - 1];
            for (expansions) |exp| {
                if (std.mem.eql(u8, exp.name, var_name) and exp.values.len == 1) {
                    return std.mem.eql(u8, exp.values[0], rhs);
                }
            }
        }
    }
    return null;
}

fn findClosingPercentIdent(src: []const u8, start: usize) ?usize {
    if (start >= src.len) return null;
    if (!std.ascii.isAlphabetic(src[start]) and src[start] != '_') return null;
    var i = start + 1;
    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) : (i += 1) {}
    if (i + 1 < src.len and src[i] == '%' and src[i + 1] == '%') return i;
    return null;
}

fn extractMacroIdent(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) : (i += 1) {}
    return s[0..i];
}

fn isIgnoredDefine(name: []const u8, ignored: []const []const u8) bool {
    for (ignored) |ign| {
        if (std.mem.eql(u8, name, ign)) return true;
    }
    return false;
}

fn findEntryIndex(entries: []const SourceInfo.MacroEntry, name: []const u8) ?usize {
    for (entries, 0..) |e, idx| {
        if (std.mem.eql(u8, e.name, name)) return idx;
    }
    return null;
}

fn findAtVarIndex(entries: []const SourceInfo.AtVarEntry, name: []const u8) ?usize {
    for (entries, 0..) |e, idx| {
        if (std.mem.eql(u8, e.name, name)) return idx;
    }
    return null;
}

fn findClosingAtIdent(src: []const u8, start: usize) ?usize {
    if (start >= src.len) return null;
    if (!std.ascii.isAlphabetic(src[start]) and src[start] != '_') return null;
    var i = start + 1;
    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) : (i += 1) {}
    if (i < src.len and src[i] == '@') return i;
    return null;
}

fn parseOcamlVersion(b: *std.Build, m4_src: []const u8, version_file_src: []const u8) OcamlVersionInfo {
    const dev_str = extractM4Define(m4_src, "OCAML__DEVELOPMENT_VERSION");
    const dev_version = std.mem.eql(u8, dev_str, "true");
    const major = std.fmt.parseInt(u32, extractM4Define(m4_src, "OCAML__VERSION_MAJOR"), 10) catch @panic("Invalid OCAML__VERSION_MAJOR");
    const minor = std.fmt.parseInt(u32, extractM4Define(m4_src, "OCAML__VERSION_MINOR"), 10) catch @panic("Invalid OCAML__VERSION_MINOR");
    const patchlevel = std.fmt.parseInt(u32, extractM4Define(m4_src, "OCAML__VERSION_PATCHLEVEL"), 10) catch @panic("Invalid OCAML__VERSION_PATCHLEVEL");
    const release_number: ?u32 = if (extractM4DefineOptional(m4_src, "OCAML__RELEASE_NUMBER")) |rn_str|
        (std.fmt.parseInt(u32, rn_str, 10) catch @panic("Invalid OCAML__RELEASE_NUMBER"))
    else
        null;
    const extra = extractM4Define(m4_src, "OCAML__VERSION_EXTRA");
    const extra_prefix = extractM4Define(m4_src, "OCAML__VERSION_EXTRA_PREFIX");
    const magic_prefix = extractM4DefineOptional(m4_src, "MAGIC_NUMBER__PREFIX");
    const magic_version = extractM4DefineOptional(m4_src, "MAGIC_NUMBER__VERSION");
    const exec_format = extractM4DefineOptional(m4_src, "EXEC__FORMAT");

    const version_string = if (extra.len > 0)
        b.fmt("{d}.{d}.{d}{s}{s}", .{ major, minor, patchlevel, extra_prefix, extra })
    else
        b.fmt("{d}.{d}.{d}", .{ major, minor, patchlevel });

    // Cross-check with VERSION file first line
    var v_lines = std.mem.splitScalar(u8, version_file_src, '\n');
    const first_line = std.mem.trim(u8, v_lines.next() orelse "", " \t\r");
    if (!std.mem.eql(u8, first_line, version_string)) {
        std.debug.panic(
            "Version safety check failed: ocaml_version.m4 computed '{s}', but VERSION file has '{s}'",
            .{ version_string, first_line },
        );
    }

    const version_number = major * 10000 + minor * 100 + patchlevel;
    const exec_magic_length: ?usize = if (magic_prefix != null and exec_format != null and magic_version != null)
        magic_prefix.?.len + exec_format.?.len + magic_version.?.len
    else
        null;

    return .{
        .sem_ver = .{
            .major = major,
            .minor = minor,
            .patch = patchlevel,
            .pre = if (extra.len > 0) extra else null,
        },
        .dev_version = dev_version,
        .major = major,
        .minor = minor,
        .patchlevel = patchlevel,
        .release_number = release_number,
        .extra = extra,
        .extra_prefix = extra_prefix,
        .version_string = version_string,
        .version_number = version_number,
        .magic_prefix = magic_prefix,
        .magic_version = magic_version,
        .exec_format = exec_format,
        .exec_magic_length = exec_magic_length,
    };
}

fn extractM4Define(m4_src: []const u8, key: []const u8) []const u8 {
    return extractM4DefineOptional(m4_src, key) orelse {
        std.debug.panic("m4 safety check failed: m4_define for '{s}' not found in build-aux/ocaml_version.m4", .{key});
    };
}

fn extractM4DefineOptional(m4_src: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, m4_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "m4_define(")) {
            const inner = line["m4_define(".len..];
            // Match either `[KEY], [` or `KEY, [`
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
