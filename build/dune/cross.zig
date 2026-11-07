//! A lock directory package's `dune build -p <pkgs>` in a cross context, which
//! `cross_pkg.ml` marks. It builds with two contexts, `default` for the build
//! machine and `default.<toolchain>` for the target, each with its dependencies'
//! libraries, and installs the target's files but the build machine's executables:
//! a dependency's executables only run in the project's build (preprocessors, ppx
//! drivers, ...).
//!
//! Supported: `-p` with options, and `@install`. Anything else fails, saying so.
//!
//! A package's `dune exec` (lwt's configuration program, ...) runs on the build
//! machine: it's stock dune's, with the host context's libraries.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const path = std.fs.path;
const fatal = std.process.fatal;

/// The toolchain, and the host context: set by `cross_pkg.ml`.
const marker = "DUNE_PKG_CROSS_TARGET";
const host_marker = "DUNE_PKG_CROSS_HOST";
/// All set only in a cross context's package build: one of dune's actions.
pub const markers = [_][:0]const u8{ marker, host_marker, "INSIDE_DUNE" };
pub const commands = [_][:0]const u8{ "build", "exec" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    const args = try init.minimal.args.toSlice(arena);
    // Copies: `env` frees them, as they're removed from it.
    const toolchain = try arena.dupe(u8, env.get(marker).?);
    const host = try arena.dupe(u8, env.get(host_marker).?);
    const ocamlpath = try arena.dupe(u8, env.get("OCAMLPATH") orelse "");
    inline for (&.{ "DUNE_WORKSPACE", "DUNE_BUILD_DIR" }) |name| {
        if (env.get(name) != null) fatal("cross-compiling a package: {s} isn't supported", .{name});
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    const libs: Libraries = try .split(io, arena, ocamlpath, host);
    // A context's `OCAMLPATH` is the workspace's only if the environment has none.
    inline for (&.{ "OCAMLPATH", marker, host_marker, "DUNE_CROSS_TARGET" }) |name| _ = env.swapRemove(name);
    const dune: Dune = .{ .io = io, .exe = try std.process.executablePathAlloc(io, arena), .cwd = cwd, .env = env };

    if (std.mem.eql(u8, args[1], "exec")) {
        try env.put("OCAMLPATH", try std.mem.join(arena, &.{path.delimiter}, libs.host));
        return dune.run(arena, &.{args[1..]});
    }

    const command: Command = try .parse(arena, args[2..]);
    const context = try std.fmt.allocPrint(arena, "default.{s}", .{toolchain});
    const workspace = try path.join(arena, &.{ cwd, ".dune-cross-workspace" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = workspace, .data = try std.fmt.allocPrint(arena,
        \\(lang dune 3.0)
        \\(context (default{f}))
        \\(context (default (name {f}) (host default) (toolchain {f}){f}))
        \\
    , .{ ocamlPath(libs.host), quoted(context), quoted(toolchain), ocamlPath(libs.target) }) });

    const describe = try dune.output(arena, &.{
        &.{ "describe", "package-entries" },
        command.options,
        &.{ "--workspace", workspace, "--context", context, "--format", "csexp" },
    });
    const packages = try Package.parseAll(arena, try .parse(arena, describe), context);

    var targets: std.ArrayList([]const u8) = .empty;
    for (packages) |p| for (p.entries) |e| try targets.append(arena, e.src);
    if (targets.items.len > 0) try dune.run(arena, &.{ &.{"build"}, command.options, &.{ "--workspace", workspace }, targets.items });

    // Where dune's own are: `_build/default` (`dune install` reads them there), and
    // the source tree, unless they aren't promoted.
    for (packages) |p| {
        const data = try std.fmt.allocPrint(arena, "{f}", .{p});
        const file = try std.fmt.allocPrint(arena, "{s}.install", .{p.name});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try path.join(arena, &.{ "_build", "default", file }), .data = data });
        if (command.promote_install_files) try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = data });
    }
}

/// A package's `dune build` arguments.
const Command = struct {
    /// To pass on, without targets.
    options: []const []const u8,
    /// `--promote-install-files[=<bool>]`, which `-p` turns on: `<package>.install`s
    /// in the source tree.
    promote_install_files: bool,

    /// Options whose value can be the next argument. One that isn't here would
    /// take its value for a target, and fail.
    const with_value = [_][]const u8{
        "-j",                "-p",                         "--for-release-of-packages",  "--profile",
        "--only-packages",   "--display",                  "--config-file",              "--cache",
        "--sandbox",         "--action-stdout-on-success", "--action-stderr-on-success", "--error-reporting",
        "--instrument-with", "--diff-command",             "--terminal-persistence",     "--cache-storage-mode",
    };
    /// What would change where, or for what, it builds.
    const unsupported = [_][]const u8{ "-x", "--workspace", "--root", "--build-dir", "--context", "-w", "--watch", "--passive-watch-mode" };

    fn parse(arena: Allocator, args: []const []const u8) !Command {
        var options: std.ArrayList([]const u8) = .empty;
        var has_packages = false;
        var promote_install_files = true;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "@install")) continue; // built anyway
            if (arg.len < 2 or arg[0] != '-' or std.mem.eql(u8, arg, "--"))
                fatal("cross-compiling a package: `dune build {s}` isn't supported, only @install", .{arg});

            const name = optionName(arg);
            if (isOneOf(name, &unsupported)) fatal("cross-compiling a package: `dune build {s}` isn't supported", .{name});
            if (isOneOf(name, &.{ "-p", "--for-release-of-packages" })) has_packages = true;
            if (std.mem.eql(u8, name, "--promote-install-files")) promote_install_files = parseBool(arg[name.len..]);
            try options.append(arena, arg);
            if (name.len == arg.len and isOneOf(name, &with_value)) {
                i += 1;
                if (i == args.len) fatal("`dune build {s}` without a value", .{arg});
                try options.append(arena, args[i]);
            }
        }
        if (!has_packages) fatal("cross-compiling a package: `dune build` without -p isn't supported", .{});
        return .{ .options = options.items, .promote_install_files = promote_install_files };
    }

    /// An optional value: `=<bool>`, or nothing, `true`.
    fn parseBool(value: []const u8) bool {
        if (value.len == 0 or std.mem.eql(u8, value, "=true")) return true;
        if (std.mem.eql(u8, value, "=false")) return false;
        fatal("`dune build --promote-install-files{s}`: not a bool", .{value});
    }

    /// `--name` of `--name=value`, `-x` of `-xvalue`.
    fn optionName(arg: []const u8) []const u8 {
        if (!std.mem.startsWith(u8, arg, "--")) return arg[0..2];
        return arg[0 .. std.mem.findScalar(u8, arg, '=') orelse arg.len];
    }

    fn isOneOf(name: []const u8, names: []const []const u8) bool {
        for (names) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }
};

/// The dependencies' libraries, from `OCAMLPATH`: the cross context's, and the host
/// context's builds of the same packages, which `cross_pkg.ml` makes it depend on.
const Libraries = struct {
    target: []const []const u8,
    host: []const []const u8,

    fn split(io: Io, arena: Allocator, ocamlpath: []const u8, host_context: []const u8) !Libraries {
        var target: std.ArrayList([]const u8) = .empty;
        var host: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, ocamlpath, path.delimiter);
        while (it.next()) |dir| {
            if (!exists(io, dir)) continue; // a package without libraries
            const host_dir = try hostDir(arena, dir, host_context);
            if (!exists(io, host_dir)) fatal("{s}: no build for the build machine, {s}", .{ dir, host_dir });
            try target.append(arena, dir);
            try host.append(arena, host_dir);
        }
        return .{ .target = target.items, .host = host.items };
    }

    /// `<build>/_private/<context>/.pkg/...`, in the host context.
    fn hostDir(arena: Allocator, dir: []const u8, host_context: []const u8) ![]const u8 {
        var components = path.componentIterator(dir);
        while (components.next()) |component| {
            if (!std.mem.eql(u8, component.name, "_private")) continue;
            const context = components.next() orelse break;
            const start = context.path.len - context.name.len;
            return std.mem.concat(arena, u8, &.{ dir[0..start], host_context, dir[context.path.len..] });
        }
        fatal("OCAMLPATH has {s}: not a package's", .{dir});
    }
};

/// This dune, run for a package's build.
const Dune = struct {
    io: Io,
    exe: []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,

    /// Exits as it does, if it fails.
    fn run(dune: Dune, arena: Allocator, args: []const []const []const u8) !void {
        var child = try std.process.spawn(dune.io, .{ .argv = try dune.argv(arena, args), .cwd = .{ .path = dune.cwd }, .environ_map = dune.env });
        exitIfFailed(try child.wait(dune.io));
    }

    /// Its output. Exits as it does, with its errors, if it fails.
    fn output(dune: Dune, arena: Allocator, args: []const []const []const u8) ![]const u8 {
        const result = try std.process.run(arena, dune.io, .{ .argv = try dune.argv(arena, args), .cwd = .{ .path = dune.cwd }, .environ_map = dune.env });
        if (!result.term.success()) std.debug.print("{s}", .{result.stderr});
        exitIfFailed(result.term);
        return result.stdout;
    }

    fn argv(dune: Dune, arena: Allocator, args: []const []const []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(arena, dune.exe);
        for (args) |a| try list.appendSlice(arena, a);
        return list.items;
    }

    fn exitIfFailed(term: std.process.Child.Term) void {
        switch (term) {
            .exited => |code| if (code != 0) std.process.exit(code),
            else => std.process.exit(1),
        }
    }
};

/// A package's install entries, for its `<name>.install`.
const Package = struct {
    name: []const u8,
    entries: []const Entry,

    /// From `dune describe package-entries --format csexp`: `((<name> (((source ..)
    /// (entry ((src ..) (kind File) (dst <dst>) (section LIB) (optional false)))) ..)) ..)`.
    fn parseAll(arena: Allocator, describe: Sexp, context: []const u8) ![]const Package {
        const list = try describe.asList();
        const packages = try arena.alloc(Package, list.len);
        for (packages, list) |*package, item| {
            const pair = try item.asList();
            if (pair.len != 2) return error.BadPackageEntries;
            const name = try pair[0].asAtom();
            const sourced = try pair[1].asList();
            const entries = try arena.alloc(Entry, sourced.len);
            for (entries, sourced) |*entry, s| entry.* = try .parse(arena, try s.field("entry"), name, context);
            package.* = .{ .name = name, .entries = entries };
        }
        return packages;
    }

    pub fn format(package: Package, w: *Io.Writer) Io.Writer.Error!void {
        for (std.enums.values(Section)) |section| {
            var started = false;
            for (package.entries) |entry| {
                if (entry.section != section) continue;
                if (!started) try w.print("{t}: [\n", .{section});
                started = true;
                try w.print("  \"{s}{f}\" {{{f}}}\n", .{ if (entry.optional) "?" else "", escaped(entry.src), quoted(entry.dst) });
            }
            if (started) try w.writeAll("]\n");
        }
    }
};

const Entry = struct {
    section: Section,
    dst: []const u8,
    optional: bool,
    /// In dune's install layout, `_build/install/<context>/...`: a target.
    src: []const u8,

    fn parse(arena: Allocator, entry: Sexp, package: []const u8, context: []const u8) !Entry {
        const kind = try (try entry.field("kind")).asAtom();
        if (!std.mem.eql(u8, kind, "File")) fatal("{s}: installing a {s} isn't supported in a cross build", .{ package, kind });
        const section_name = try (try entry.field("section")).asAtom();
        const section = Section.parse(section_name) orelse
            fatal("{s}: installing to {s} isn't supported in a cross build", .{ package, section_name });
        const dst = try (try entry.field("dst")).asAtom();

        const dir, const in_package_dir = section.dir();
        const src_context = if (section.isExecutable(dst)) "default" else context;
        return .{
            .section = section,
            .dst = dst,
            .optional = std.mem.eql(u8, try (try entry.field("optional")).asAtom(), "true"),
            .src = if (in_package_dir)
                try std.fmt.allocPrint(arena, "_build/install/{s}/{s}/{s}/{s}", .{ src_context, dir, package, dst })
            else
                try std.fmt.allocPrint(arena, "_build/install/{s}/{s}/{s}", .{ src_context, dir, dst }),
        };
    }
};

/// The sections a prefix has: not `misc`.
const Section = enum {
    lib,
    lib_root,
    libexec,
    libexec_root,
    bin,
    sbin,
    toplevel,
    share,
    share_root,
    etc,
    doc,
    stublibs,
    man,

    fn parse(name: []const u8) ?Section {
        for (std.enums.values(Section)) |s| if (std.ascii.eqlIgnoreCase(@tagName(s), name)) return s;
        return null;
    }

    /// Its directory in a prefix, and whether its files are in a directory of their
    /// package's there (`src/install/roots.ml`).
    fn dir(s: Section) struct { []const u8, bool } {
        return switch (s) {
            .lib, .libexec => .{ "lib", true },
            .lib_root, .libexec_root => .{ "lib", false },
            .bin => .{ "bin", false },
            .sbin => .{ "sbin", false },
            .toplevel => .{ "lib/toplevel", false },
            .share => .{ "share", true },
            .share_root => .{ "share", false },
            .etc => .{ "etc", true },
            .doc => .{ "doc", true },
            .stublibs => .{ "lib/stublibs", false },
            .man => .{ "man", false },
        };
    }

    /// Plugins (`.cmxs`) load into the target's programs.
    fn isExecutable(s: Section, dst: []const u8) bool {
        return switch (s) {
            .bin, .sbin => true,
            .libexec, .libexec_root => !std.mem.endsWith(u8, dst, ".cmxs"),
            else => false,
        };
    }
};

/// A canonical S-expression: atoms are `<length>:<bytes>`, unescaped.
const Sexp = union(enum) {
    atom: []const u8,
    list: []const Sexp,

    fn parse(arena: Allocator, text: []const u8) !Sexp {
        var rest = text;
        const sexp = try parseNext(arena, &rest);
        if (rest.len != 0) return error.BadCsexp;
        return sexp;
    }

    fn parseNext(arena: Allocator, rest: *[]const u8) !Sexp {
        if (rest.len == 0) return error.BadCsexp;
        if (rest.*[0] == '(') {
            rest.* = rest.*[1..];
            var items: std.ArrayList(Sexp) = .empty;
            while (rest.len > 0 and rest.*[0] != ')') try items.append(arena, try parseNext(arena, rest));
            if (rest.len == 0) return error.BadCsexp;
            rest.* = rest.*[1..];
            return .{ .list = items.items };
        }
        const colon = std.mem.findScalar(u8, rest.*, ':') orelse return error.BadCsexp;
        const len = std.fmt.parseInt(usize, rest.*[0..colon], 10) catch return error.BadCsexp;
        const start = colon + 1;
        if (rest.len - start < len) return error.BadCsexp;
        defer rest.* = rest.*[start + len ..];
        return .{ .atom = rest.*[start..][0..len] };
    }

    fn asAtom(s: Sexp) ![]const u8 {
        return if (s == .atom) s.atom else error.BadPackageEntries;
    }

    fn asList(s: Sexp) ![]const Sexp {
        return if (s == .list) s.list else error.BadPackageEntries;
    }

    /// In a record, `((<name> <value>) ..)`, `<name>`'s value.
    fn field(s: Sexp, name: []const u8) !Sexp {
        for (try s.asList()) |f| {
            if (f != .list or f.list.len != 2 or f.list[0] != .atom) continue;
            if (std.mem.eql(u8, f.list[0].atom, name)) return f.list[1];
        }
        return error.BadPackageEntries;
    }
};

/// A string in dune's and opam's syntax, which escape alike.
fn quoted(s: []const u8) std.fmt.Alt([]const u8, writeQuoted) {
    return .{ .data = s };
}

fn writeQuoted(s: []const u8, w: *Io.Writer) Io.Writer.Error!void {
    try w.print("\"{f}\"", .{escaped(s)});
}

fn escaped(s: []const u8) std.fmt.Alt([]const u8, writeEscaped) {
    return .{ .data = s };
}

fn writeEscaped(s: []const u8, w: *Io.Writer) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"', '\\' => try w.print("\\{c}", .{c}),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
}

/// A context's `(paths (OCAMLPATH ..))`.
fn ocamlPath(dirs: []const []const u8) std.fmt.Alt([]const []const u8, writeOcamlPath) {
    return .{ .data = dirs };
}

fn writeOcamlPath(dirs: []const []const u8, w: *Io.Writer) Io.Writer.Error!void {
    if (dirs.len == 0) return;
    try w.writeAll(" (paths (OCAMLPATH");
    for (dirs) |dir| try w.print(" {f}", .{quoted(dir)});
    try w.writeAll("))");
}

fn exists(io: Io, p: []const u8) bool {
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}
