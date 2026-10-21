const std = @import("std");

pub const OcamlVersionInfo = struct {
    sem_ver: std.SemanticVersion,
    dev_version: bool,
    major: u32,
    minor: u32,
    patchlevel: u32,
    release_number: u32,
    extra: []const u8,
    extra_prefix: []const u8,
    version_string: []const u8,
    version_number: u32,
    magic_prefix: []const u8,
    magic_version: []const u8,
    exec_format: []const u8,
    exec_magic_length: usize,
};

pub const SourceInfo = struct {
    b: *std.Build,
    dep: *std.Build.Dependency,
    version: OcamlVersionInfo,
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
            .makefile_src = makefile_src,
        };
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

    /// Parses a variable assignment `var_name = ...` (with `\` line continuations)
    /// from the OCaml Makefile and expands any allowed `$(VAR)` references.
    /// Panics if the variable is missing, empty, or contains unknown `$(...)` expansions.
    pub fn parseMakefileList(
        self: SourceInfo,
        var_name: []const u8,
        expansions: []const VarExpansion,
    ) []const []const u8 {
        const alloc = self.b.allocator;
        var lines = std.mem.splitScalar(u8, self.makefile_src, '\n');

        var found = false;
        var raw_body: std.ArrayList(u8) = .empty;

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (!found) {
                if (std.mem.startsWith(u8, line, var_name)) {
                    const after = std.mem.trimStart(u8, line[var_name.len..], " \t");
                    if (std.mem.startsWith(u8, after, "=")) {
                        found = true;
                        const rhs = std.mem.trimStart(u8, after[1..], " \t");
                        if (std.mem.endsWith(u8, rhs, "\\")) {
                            raw_body.appendSlice(alloc, rhs[0 .. rhs.len - 1]) catch @panic("OOM");
                            raw_body.append(alloc, ' ') catch @panic("OOM");
                        } else {
                            raw_body.appendSlice(alloc, rhs) catch @panic("OOM");
                            break;
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
                    break;
                }
            }
        }

        if (!found) {
            std.debug.panic("Makefile safety check failed: variable '{s}' not found in OCaml Makefile", .{var_name});
        }

        var body_slice = std.mem.trim(u8, raw_body.items, " \t");
        var prefix_to_add: ?[]const u8 = null;

        // Handle $(addprefix prefix, items...) wrapper if present
        if (std.mem.startsWith(u8, body_slice, "$(addprefix ") and std.mem.endsWith(u8, body_slice, ")")) {
            const inner = body_slice["$(addprefix ".len .. body_slice.len - 1];
            const comma_idx = std.mem.indexOfScalar(u8, inner, ',') orelse {
                std.debug.panic("Malformed $(addprefix ...) in Makefile variable '{s}'", .{var_name});
            };
            prefix_to_add = std.mem.trim(u8, inner[0..comma_idx], " \t");
            body_slice = std.mem.trim(u8, inner[comma_idx + 1 ..], " \t");
        }

        var result: std.ArrayList([]const u8) = .empty;
        var tok_iter = std.mem.tokenizeAny(u8, body_slice, " \t");
        while (tok_iter.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "$(") and std.mem.endsWith(u8, tok, ")")) {
                const ref_name = tok[2 .. tok.len - 1];
                var expanded = false;
                for (expansions) |exp| {
                    if (std.mem.eql(u8, exp.name, ref_name)) {
                        for (exp.values) |v| {
                            const final_item = if (prefix_to_add) |p| self.b.fmt("{s}{s}", .{ p, v }) else v;
                            result.append(alloc, final_item) catch @panic("OOM");
                        }
                        expanded = true;
                        break;
                    }
                }
                if (!expanded) {
                    std.debug.panic(
                        "Makefile safety check failed: unexpanded variable '$({s})' in '{s}'",
                        .{ ref_name, var_name },
                    );
                }
            } else if (std.mem.indexOfScalar(u8, tok, '$') != null) {
                std.debug.panic(
                    "Makefile safety check failed: unexpected macro expression '{s}' in '{s}'",
                    .{ tok, var_name },
                );
            } else {
                const final_item = if (prefix_to_add) |p| self.b.fmt("{s}{s}", .{ p, tok }) else tok;
                result.append(alloc, final_item) catch @panic("OOM");
            }
        }

        if (result.items.len == 0) {
            std.debug.panic("Makefile safety check failed: variable '{s}' resolved to 0 items", .{var_name});
        }

        return result.items;
    }

    pub const MacroEntry = struct {
        name: []const u8,
        value: ?[]const u8,
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
            if (!used[idx]) {
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
    };

    /// Strictly renders a template using `@var@` placeholders (such as `stdlib/sys.ml.in`,
    /// `utils/config.generated.ml.in`, `otherlibs/dynlink/dynlink_config.ml.in`, `META.in`).
    /// Panics if any `@var@` in the template is missing from `entries` or if any entry is unused.
    pub fn renderAtTemplate(
        self: SourceInfo,
        template_sub_path: []const u8,
        entries: []const AtVarEntry,
    ) []const u8 {
        const alloc = self.b.allocator;
        const template_src = readFile(self.b, self.dep, template_sub_path);

        const used = alloc.alloc(bool, entries.len) catch @panic("OOM");
        @memset(used, false);

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
            if (!used[idx]) {
                std.debug.panic(
                    "Template safety check failed in '{s}': substitution '@{s}@' in zcaml table does not exist in template",
                    .{ template_sub_path, entry.name },
                );
            }
        }

        return out.items;
    }
};

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
    const release_number = std.fmt.parseInt(u32, extractM4Define(m4_src, "OCAML__RELEASE_NUMBER"), 10) catch @panic("Invalid OCAML__RELEASE_NUMBER");
    const extra = extractM4Define(m4_src, "OCAML__VERSION_EXTRA");
    const extra_prefix = extractM4Define(m4_src, "OCAML__VERSION_EXTRA_PREFIX");
    const magic_prefix = extractM4Define(m4_src, "MAGIC_NUMBER__PREFIX");
    const magic_version = extractM4Define(m4_src, "MAGIC_NUMBER__VERSION");
    const exec_format = extractM4Define(m4_src, "EXEC__FORMAT");

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
    const exec_magic_length = magic_prefix.len + exec_format.len + magic_version.len;

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
    std.debug.panic("m4 safety check failed: m4_define for '{s}' not found in build-aux/ocaml_version.m4", .{key});
}
