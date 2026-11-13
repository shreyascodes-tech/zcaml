//! Bootstraps dune for a target: `boot/bootstrap.ml`'s two steps, run directly.
//!
//! ```text
//! tool <dune-src> <host-toolchain> <target-toolchain> <target-os> <main-obj> <out-file> [<macos-sdk>]
//! ```
//!
//! `<main-obj>` is linked in, with the program's `main` (`main.zig`).
//!
//! For macOS, `zcaml-cc` gets the SDK (dune's file watcher uses `CoreServices`)
//! from `ZCAML_MACOS_SDK`.
//!
//! `boot/duneboot.ml` builds `_boot/dune.exe`, the binary dune releases, with the
//! first `ocamlc`/`ocamlopt` on `PATH`: the target toolchain's. It runs in the host
//! toolchain's toplevel, which `bootstrap.ml` would look up on `PATH` too, so this
//! does what it does with the host's `ocamllex` and `ocaml`.
//!
//! The bootstrap takes no compiler flags, but `ocamlopt` reads `OCAMLPARAM` (`ocamlParam`).
//!
//! The bootstrap writes into the source tree: it runs in a copy, next to `<out-file>`.
//! `zig` must be on `PATH`, for the toolchains' `zig cc`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const path = std.fs.path;

const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7 and args.len != 8) fatal("usage: tool <dune-src> <host-toolchain> <target-toolchain> <target-os> <main-obj> <out-file> [<macos-sdk>]", .{});
    // Absolute: the commands run in `work`.
    const cwd = try std.process.currentPathAlloc(io, arena);
    const src = try path.resolve(arena, &.{ cwd, args[1] });
    const host_bin = try path.resolve(arena, &.{ cwd, args[2], "bin" });
    const target_bin = try path.resolve(arena, &.{ cwd, args[3], "bin" });
    const os = std.meta.stringToEnum(std.Target.Os.Tag, args[4]) orelse fatal("unknown OS '{s}'", .{args[4]});
    const main_obj = try path.resolve(arena, &.{ cwd, args[5] });
    const out = try path.resolve(arena, &.{ cwd, args[6] });

    const work = try path.join(arena, &.{ path.dirname(out).?, "work" });
    Dir.cwd().deleteTree(io, work) catch {};
    try copyTree(io, arena, src, work);
    defer Dir.cwd().deleteTree(io, work) catch {};
    try setVersion(io, arena, work);
    try addCrossHooks(io, arena, work);

    var env = try init.environ_map.clone(arena);
    try env.put("PATH", try std.mem.join(arena, if (builtin.os.tag == .windows) ";" else ":", &.{
        target_bin,
        host_bin,
        init.environ_map.get("PATH") orelse "",
    }));
    if (args.len == 8) try env.put("ZCAML_MACOS_SDK", try path.resolve(arena, &.{ cwd, args[7] }));

    try run(io, arena, work, &env, &.{
        try path.join(arena, &.{ host_bin, "ocamllex" ++ exe_ext }),
        "-q",
        "-o",
        "boot/pps.ml",
        "boot/pps.mll",
    });
    // What `bootstrap.ml` feeds the toplevel (which resolves paths from the script's directory).
    var script: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "pps", "types", "libs" }) |m| try script.print(arena, "#mod_use \"{s}/boot/{s}.ml\";;\n", .{ work, m });
    try script.print(arena, "#use \"{s}/boot/duneboot.ml\";;\n", .{work});
    try Dir.cwd().writeFile(io, .{ .sub_path = try path.join(arena, &.{ work, "boot", "main.top" }), .data = script.items });
    try env.put("OCAMLPARAM", try ocamlParam(arena, os, main_obj));
    try run(io, arena, work, &env, &.{
        try path.join(arena, &.{ host_bin, "ocaml" ++ exe_ext }),
        "-I",
        "+unix",
        "unix.cma",
        "boot/main.top",
    });

    // A copy, not a rename: `out` can't be inside `work`, which is removed.
    try Dir.copyFile(Dir.cwd(), try path.join(arena, &.{ work, "_boot", "dune.exe" }), Dir.cwd(), out, io, .{});
}

/// zcaml's revision of the pinned dune, in its version (`3.24.2+zcaml.5`): one more
/// for each release of the same dune. The release tag says it (`dune-v3.24.2-zcaml.5`).
const revision = 5;

/// What `dune subst` does for releases, so `dune --version` isn't `n/a`: the bootstrap
/// takes the version from `(version <v>)` in `dune-project`. The source is a release
/// commit, whose `CHANGES.md` starts with its version: `3.24.2 (2026-08-03)`.
fn setVersion(io: Io, arena: std.mem.Allocator, work: []const u8) !void {
    const changes = try Dir.cwd().readFileAlloc(io, try path.join(arena, &.{ work, "CHANGES.md" }), arena, .unlimited);
    var lines = std.mem.tokenizeScalar(u8, changes, '\n');
    const version = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "<!--")) continue;
        const v = line[0 .. std.mem.findScalar(u8, line, ' ') orelse line.len];
        _ = std.SemanticVersion.parse(v) catch fatal("CHANGES.md starts with '{s}', not a release: pin dune to a release commit", .{line});
        break v;
    } else fatal("CHANGES.md has no release", .{});

    const project_path = try path.join(arena, &.{ work, "dune-project" });
    const project = try Dir.cwd().readFileAlloc(io, project_path, arena, .unlimited);
    try Dir.cwd().writeFile(io, .{ .sub_path = project_path, .data = try std.fmt.allocPrint(arena, "{s}\n(version {s}+zcaml.{d})\n", .{ project, version, revision }) });
}

/// Cross-compiling a lock directory's packages with `-x` (`cross_pkg.ml`): the only
/// changes to dune's source.
fn addCrossHooks(io: Io, arena: std.mem.Allocator, work: []const u8) !void {
    try Dir.cwd().writeFile(io, .{
        .sub_path = try path.join(arena, &.{ work, "src", "dune_rules", "cross_pkg.ml" }),
        .data = @embedFile("cross_pkg.ml"),
    });
    // Inactive `-x` contexts' package builds stay, as dune keeps active ones.
    try replaceOnce(io, arena, work, "src/dune_rules/gen_rules.ml",
        \\        (Subdir_set.of_list
        \\           (List.rev_map contexts ~f:(fun context_name ->
        \\              Filename.of_string_exn (Context_name.to_string context_name))))
    ,
        \\        (Cross_pkg.private_dirs ~dir contexts)
    );
    // Internal errors may be ours.
    try replaceOnce(io, arena, work, "src/dune_util/report_error.ml",
        \\"Internal error! Please report to https://github.com/ocaml/dune/issues, \
    ,
        \\"Internal error! This is zcaml's dune, with changes: please report to \
        \\                https://github.com/zcaml/zcaml/issues (or \
        \\                https://github.com/ocaml/dune/issues, if upstream dune fails too), \
    );
    // A context with a findlib toolchain compiles with it, not the lock directory's
    // `ocaml`: as a lock directory without one does.
    try replaceOnce(io, arena, work, "src/dune_rules/context.ml",
        \\           | Lock _ ->
        \\             Pkg_rules.ocaml_toolchain builder.name
    ,
        \\           | Lock _ when Option.is_some builder.findlib_toolchain ->
        \\             toolchain `Lock >>= Cross_pkg.check_compiler builder.name
        \\           | Lock _ ->
        \\             Pkg_rules.ocaml_toolchain builder.name
    );
    // Its rules' `(run ocamlmklib ...)`, ..., run the toolchain's.
    try replaceOnce(io, arena, work, "src/dune_rules/action_unexpanded.ml",
        \\               Artifacts.binary ?hint ~loc:(Some loc) ~where ~dir artifacts s)
    ,
        \\               let* context = Context.DB.by_dir env.dir in
        \\               Cross_pkg.toolchain_tool
        \\                 ~findlib_toolchain:(Context.findlib_toolchain context)
        \\                 ~ocaml:(fun () -> Context.ocaml context)
        \\                 s
        \\               >>= (function
        \\                | Some path -> Memo.return (Ok path)
        \\                | None -> Artifacts.binary ?hint ~loc:(Some loc) ~where ~dir artifacts s))
    );
    // Its packages are the lock directory's for the target's platform.
    try replaceOnce(io, arena, work, "src/dune_rules/pkg_rules.ml",
        \\               and* platform = Lock_dir.Sys_vars.solver_env in
    ,
        \\               and* platform = Cross_pkg.platform ctx in
    );
    try replaceOnce(io, arena, work, "src/dune_rules/pkg_rules.ml",
        \\    and* platform = Lock_dir.Sys_vars.solver_env in
        \\    let+ t = of_ctx ctx ~allow_sharing:true in
    ,
        \\    and* platform = Cross_pkg.platform ctx in
        \\    let+ t = of_ctx ctx ~allow_sharing:true in
    );
    try replaceOnce(io, arena, work, "src/dune_rules/pkg_rules.ml",
        \\      let* platform = Lock_dir.Sys_vars.solver_env in
        \\      let choose_for_current_platform field =
    ,
        \\      let* platform = Cross_pkg.platform (Package_universe.context_name package_universe) in
        \\      let choose_for_current_platform field =
    );
    // A package's build, marked in a context with one. The host context's builds
    // of its dependencies are of those names, and their dependencies.
    try replaceOnce(io, arena, work, "src/dune_rules/pkg_rules.ml",
        \\  >>> add_env (Pkg.exported_env pkg) build_action
    ,
        \\  >>> Cross_pkg.build_action context_name (add_env (Pkg.exported_env pkg) build_action)
        \\        ~host_deps:(fun host ->
        \\          let open Memo.O in
        \\          let names =
        \\            Package.Name.Set.of_list
        \\              (List.map (Pkg.deps_closure pkg) ~f:(fun (dep : Pkg.t) -> dep.info.name))
        \\          in
        \\          let* db = DB.of_ctx host ~allow_sharing:false in
        \\          Pkg_digest.Map.values db.pkg_digest_table
        \\          |> List.filter ~f:(fun (entry : DB.Pkg_table.entry) ->
        \\            Package.Name.Set.mem names entry.pkg_digest.name)
        \\          |> Memo.parallel_map ~f:(fun (entry : DB.Pkg_table.entry) ->
        \\            Resolve.resolve db Loc.none entry.pkg_digest (Dependencies host))
        \\          >>| Pkg.top_closure
        \\          >>| List.map ~f:(fun (dep : Pkg.t) ->
        \\            dep.paths.target_dir, (Pkg.install_roots dep).lib_root))
    );
}

/// Replaces `old`, which must be in the file exactly once: fails loudly when dune changes.
fn replaceOnce(io: Io, arena: std.mem.Allocator, work: []const u8, file: []const u8, old: []const u8, new: []const u8) !void {
    const full = try path.join(arena, &.{ work, file });
    const text = try Dir.cwd().readFileAlloc(io, full, arena, .unlimited);
    const i = std.mem.find(u8, text, old) orelse fatal("{s}: no '{s}' to hook into: update addCrossHooks for this dune", .{ file, old });
    if (std.mem.findPos(u8, text, i + old.len, old) != null) fatal("{s}: '{s}' more than once: update addCrossHooks for this dune", .{ file, old });
    try Dir.cwd().writeFile(io, .{ .sub_path = full, .data = try std.mem.concat(arena, u8, &.{ text[0..i], new, text[i + old.len ..] }) });
}

/// `OCAMLPARAM` for the bootstrap's `ocamlopt` runs, read after the command line
/// (`_,`), for its link of `dune.exe`:
/// - `cclib=<main-obj>`: one more object, ahead of the runtime's `libasmrun.a`, whose
///   `main` it replaces. Compiles ignore `cclib`.
/// - `ccopt=-s`: a stripped binary, ~25% smaller. OCaml backtraces need neither the
///   symbols nor DWARF, and `-s` does nothing in compiles. Not on Windows, where the
///   linker is flexlink, without `-s`, and there is nothing to strip.
fn ocamlParam(arena: std.mem.Allocator, os: std.Target.Os.Tag, main_obj: []const u8) ![]const u8 {
    // `OCAMLPARAM` is `,`-separated, and `cclib` a space-separated list.
    if (std.mem.findAny(u8, main_obj, ", \t") != null) fatal("'{s}': OCAMLPARAM can't hold a path with ',' or spaces", .{main_obj});
    return std.fmt.allocPrint(arena, "_,cclib={s}{s}", .{ main_obj, if (os == .windows) "" else ",ccopt=-s" });
}

fn copyTree(io: Io, arena: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    var src_dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    try Dir.cwd().createDirPath(io, dest);
    var dest_dir = try Dir.cwd().openDir(io, dest, .{});
    defer dest_dir.close(io);

    var walker = try src_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest_dir.createDirPath(io, entry.path),
        .file => try Dir.copyFile(src_dir, entry.path, dest_dir, entry.path, io, .{}),
        else => {},
    };
}

fn run(io: Io, arena: std.mem.Allocator, cwd: []const u8, env: *const std.process.Environ.Map, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = env });
    const term = try child.wait(io);
    if (!term.success()) fatal("(cd {s} && {s}) failed: {any}", .{ cwd, try std.mem.join(arena, " ", argv), term });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
