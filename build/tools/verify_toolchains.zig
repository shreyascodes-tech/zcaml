//! `zig build -Docaml verify`: smoke-test installed toolchains (`<root_dir>/host-*/target-*`)
//! by compiling `test/fixtures` with every compiler, and running the results on the
//! target (natively, under QEMU / Wine, or later from a deferred bundle on another OS).
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const InputDir = utils.InputDir;

root_dir: []const u8,
fixtures_dir: InputDir,
host: ?[]const u8 = null,
target: ?[]const u8 = null,
jobs: usize = 8,
/// Save the target executables of pairs this machine can't run, for `run_deferred`.
save_deferred: ?[]const u8 = null,
/// Run the bundles saved by `save_deferred` on another machine.
run_deferred: ?[]const u8 = null,

const VerifyToolchains = @This();

pub fn run(self: *VerifyToolchains, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cur = currentMachineTriple();

    const cache_dir = blk: {
        if (init.environ_map.get("XDG_CACHE_HOME")) |xdg| break :blk try std.fs.path.join(arena, &.{ xdg, "zcaml" });
        if (init.environ_map.get("LOCALAPPDATA")) |appdata| break :blk try std.fs.path.join(arena, &.{ appdata, "zcaml" });
        const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/tmp";
        break :blk try std.fs.path.join(arena, &.{ home, ".cache", "zcaml" });
    };
    try Dir.cwd().createDirPath(io, cache_dir);

    var ctx: Context = .{
        .init = init,
        .cache_dir = cache_dir,
        .fixtures_abs = try Dir.cwd().realPathFileAlloc(io, self.fixtures_dir.path(), arena),
        .save_deferred_abs = if (self.save_deferred) |sd| blk: {
            try Dir.cwd().createDirPath(io, sd);
            break :blk try Dir.cwd().realPathFileAlloc(io, sd, arena);
        } else null,
    };

    if (self.run_deferred) |rd| {
        try Dir.cwd().createDirPath(io, rd);
        try runDeferredBundles(&ctx, try Dir.cwd().realPathFileAlloc(io, rd, arena));
        if (!pathExists(io, self.root_dir)) return;
    }

    const root_abs = try Dir.cwd().realPathFileAlloc(io, self.root_dir, arena);
    var runnable: std.ArrayList(PairJob) = .empty;
    var skipped_count: usize = 0;
    for (try discoverPairs(io, arena, root_abs, self.host, self.target)) |job| {
        if (canRun(job.host, cur, false)) {
            try runnable.append(arena, job);
        } else {
            skipped_count += 1;
        }
    }
    std.mem.sort(PairJob, runnable.items, cur, slowestFirst);

    std.debug.print(
        "==> Running zcaml toolchain verification on {s} ({d} runnable, {d} for other host OS, jobs={d})\n",
        .{ cur.raw, runnable.items.len, skipped_count, self.jobs },
    );

    // Provision sysroots and the Wine prefix up front, not concurrently from the workers.
    var needed_sysroots: std.StringHashMapUnmanaged(Triple) = .empty;
    var needs_wine = false;
    for (runnable.items) |job| {
        if (job.host.isLinux()) try needed_sysroots.put(arena, job.host.raw, job.host);
        if (job.target.isLinux() and canRun(job.target, cur, true)) try needed_sysroots.put(arena, job.target.raw, job.target);
        if (usesWine(job.target, cur)) needs_wine = true;
    }
    var sys_it = needed_sysroots.valueIterator();
    while (sys_it.next()) |t| _ = try ensureSysroot(init, cache_dir, t.*);
    if (needs_wine) initWinePrefix(init);

    const start_ts = Io.Clock.awake.now(io);
    var next_idx: std.atomic.Value(usize) = .init(0);
    var fail_count: std.atomic.Value(usize) = .init(0);

    const worker_count = @min(self.jobs, runnable.items.len);
    if (worker_count <= 1) {
        workerFn(&ctx, runnable.items, &next_idx, &fail_count);
    } else {
        const threads = try gpa.alloc(std.Thread, worker_count);
        defer gpa.free(threads);
        for (threads) |*th| {
            th.* = try std.Thread.spawn(.{}, workerFn, .{ &ctx, runnable.items, &next_idx, &fail_count });
        }
        for (threads) |th| th.join();
    }

    const elapsed = start_ts.untilNow(io, .awake);
    const failed = fail_count.load(.seq_cst);
    std.debug.print(
        "\n==> Completed {d} toolchain verifications in {f} ({d} passed, {d} failed)\n",
        .{ runnable.items.len, elapsed, runnable.items.len - failed, failed },
    );
    if (failed > 0) std.process.exit(1);
}

const Context = struct {
    init: std.process.Init,
    cache_dir: []const u8,
    fixtures_abs: []const u8,
    save_deferred_abs: ?[]const u8,
    print_mutex: Io.Mutex = .init,
    wine_mutex: Io.Mutex = .init,
};

const PairJob = struct {
    prefix_abs: []const u8,
    host: Triple,
    target: Triple,
};

/// `<root_abs>/host-<triple>/target-<triple>` install prefixes, sorted.
fn discoverPairs(
    io: Io,
    arena: Allocator,
    root_abs: []const u8,
    host_filter: ?[]const u8,
    target_filter: ?[]const u8,
) ![]PairJob {
    var jobs: std.ArrayList(PairJob) = .empty;
    for (try listDirs(io, arena, root_abs, "host-")) |h_name| {
        const host = Triple.parse(h_name["host-".len..]);
        if (!host.matchesFilter(arena, host_filter)) continue;
        const host_abs = try std.fs.path.join(arena, &.{ root_abs, h_name });
        for (try listDirs(io, arena, host_abs, "target-")) |t_name| {
            const target = Triple.parse(t_name["target-".len..]);
            if (!target.matchesFilter(arena, target_filter)) continue;
            try jobs.append(arena, .{
                .prefix_abs = try std.fs.path.join(arena, &.{ host_abs, t_name }),
                .host = host,
                .target = target,
            });
        }
    }
    return jobs.items;
}

/// Start the slowest pairs (Wine, emulated hosts) first.
fn slowestFirst(cur: Triple, a: PairJob, b: PairJob) bool {
    const pa = cost(cur, a);
    const pb = cost(cur, b);
    if (pa != pb) return pa > pb;
    const h_cmp = std.mem.order(u8, a.host.raw, b.host.raw);
    if (h_cmp != .eq) return h_cmp == .lt;
    return std.mem.order(u8, a.target.raw, b.target.raw) == .lt;
}

fn cost(cur: Triple, job: PairJob) u32 {
    var score: u32 = 0;
    if (job.target.isWindows()) score += 100;
    if (!std.mem.eql(u8, job.host.arch, cur.arch)) score += 80;
    if (job.host.isMusl() != cur.isMusl()) score += 20;
    if (!std.mem.eql(u8, job.target.arch, cur.arch)) score += 10;
    return score;
}

fn workerFn(
    ctx: *Context,
    jobs: []const PairJob,
    next_idx: *std.atomic.Value(usize),
    fail_count: *std.atomic.Value(usize),
) void {
    const io = ctx.init.io;
    while (true) {
        const idx = next_idx.fetchAdd(1, .seq_cst);
        if (idx >= jobs.len) break;

        var job_arena_state = std.heap.ArenaAllocator.init(ctx.init.gpa);
        defer job_arena_state.deinit();
        const arena = job_arena_state.allocator();

        const job = jobs[idx];
        const t0 = Io.Clock.awake.now(io);
        const pair_label = std.fmt.allocPrint(arena, "{s} -> {s}", .{
            job.host.shortName(arena),
            job.target.shortName(arena),
        }) catch @panic("OOM");

        if (verifyPair(ctx, arena, job)) |status| {
            const dt = t0.untilNow(io, .awake);
            ctx.print_mutex.lockUncancelable(io);
            defer ctx.print_mutex.unlock(io);
            std.debug.print("  [OK]   {s:<45} ({f}) {s}\n", .{ pair_label, dt, status });
        } else |err| {
            _ = fail_count.fetchAdd(1, .seq_cst);
            ctx.print_mutex.lockUncancelable(io);
            defer ctx.print_mutex.unlock(io);
            std.debug.print("  [FAIL] {s}: {t}\n", .{ pair_label, err });
        }
    }
}

fn verifyPair(ctx: *Context, arena: Allocator, job: PairJob) ![]const u8 {
    const io = ctx.init.io;
    const cur = currentMachineTriple();

    // Concurrent wineserver operations race.
    const uses_wine = usesWine(job.target, cur);
    if (uses_wine) ctx.wine_mutex.lockUncancelable(io);
    defer if (uses_wine) ctx.wine_mutex.unlock(io);

    var rand_int: u64 = undefined;
    io.random(@ptrCast(&rand_int));
    const tmp_base = ctx.init.environ_map.get("RUNNER_TEMP") orelse
        ctx.init.environ_map.get("TEMP") orelse
        ctx.init.environ_map.get("TMP") orelse
        "/tmp";
    const work_dir = try std.fs.path.join(arena, &.{
        tmp_base,
        try std.fmt.allocPrint(arena, "zcaml-verify-{s}-{s}-{s}", .{
            job.host.shortName(arena),
            job.target.shortName(arena),
            std.fmt.hex(rand_int),
        }),
    });
    try Dir.cwd().createDirPath(io, work_dir);
    defer Dir.cwd().deleteTree(io, work_dir) catch {};
    try copyDirFiles(io, arena, ctx.fixtures_abs, work_dir);

    const bin_dir = try std.fs.path.join(arena, &.{ job.prefix_abs, "bin" });
    const stublibs_dir = try std.fs.path.join(arena, &.{ job.prefix_abs, "lib", "ocaml", "stublibs" });

    var host: Host = .{
        .ctx = ctx,
        .arena = arena,
        .wrap = try buildExecWrapper(ctx, arena, job.host, &.{stublibs_dir}),
        .bin_dir = bin_dir,
        .triple = job.host,
        .cwd = work_dir,
    };
    const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const parent_path = ctx.init.environ_map.get("PATH") orelse "/usr/bin:/bin";
    var new_path = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ bin_dir, path_sep, parent_path });
    // Emulated hosts: compilers run `flexlink` by name, so wrap it too.
    const flexlink_bin = try std.fs.path.join(arena, &.{ bin_dir, "flexlink" });
    if (host.wrap.prefix_argv.len > 0 and !job.host.isWindows() and pathExists(io, flexlink_bin)) {
        const shim_dir = try std.fs.path.join(arena, &.{ work_dir, "host-shims" });
        try Dir.cwd().createDirPath(io, shim_dir);
        var script: std.ArrayList(u8) = .empty;
        try script.appendSlice(arena, "#!/bin/sh\nexec");
        for (host.wrap.prefix_argv) |a| try script.print(arena, " '{s}'", .{a});
        try script.print(arena, " '{s}' \"$@\"\n", .{flexlink_bin});
        const shim_path = try std.fs.path.join(arena, &.{ shim_dir, "flexlink" });
        try Dir.cwd().writeFile(io, .{ .sub_path = shim_path, .data = script.items, .flags = .{ .permissions = .executable_file } });
        new_path = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ shim_dir, path_sep, new_path });
    }
    try host.wrap.env.put("PATH", new_path);

    const t_ext = job.target.exeExt();

    const cfg_out = try host.run("ocamlc.opt", &.{"-config"});
    const has_natdynlink = std.mem.indexOf(u8, cfg_out, "native_dynlink: true") != null;
    const has_shared_libs = std.mem.indexOf(u8, cfg_out, "supports_shared_libraries: true") != null;

    for ([_][]const u8{ "ocamlc.byte", "ocamlopt.byte", "ocamllex.byte" }) |tool| _ = try host.runByte(tool, &.{"-version"});
    for ([_][]const u8{ "ocamlopt.opt", "ocamllex.opt", "ocamldep.opt", "ocamlobjinfo.opt" }) |tool| _ = try host.run(tool, &.{"-version"});
    if (job.host.eql(job.target)) _ = try host.run("ocamldoc.opt", &.{"-version"});

    _ = try host.run("ocamlyacc", &.{"calc_parser.mly"});
    _ = try host.run("ocamllex.opt", &.{"calc_lexer.mll"});

    _ = try host.run("ocamlc.opt", &.{ "-c", "cstub.c", "-o", "cstub_byt.o" });
    _ = try host.run("ocamlopt.opt", &.{ "-c", "cstub.c", "-o", "cstub_nat.o" });

    // Pack sub_a + sub_b into `Packed`. Zig's partial linker (`ld -r`) can't handle
    // every COFF / Mach-O relocation, so those targets use an archive instead.
    _ = try host.run("ocamlc.opt", &.{ "-c", "sub_a.ml", "sub_b.ml" });
    _ = try host.run("ocamlc.opt", &.{ "-pack", "-o", "packed.cmo", "sub_a.cmo", "sub_b.cmo" });
    const byte_pack_obj: []const u8 = if (!job.target.isLinux()) blk: {
        _ = try host.run("ocamlc.opt", &.{ "-c", "packed.ml" });
        _ = try host.run("ocamlc.opt", &.{ "-a", "-o", "packed_lib.cma", "sub_a.cmo", "sub_b.cmo", "packed.cmo" });
        break :blk "packed_lib.cma";
    } else "packed.cmo";

    for ([_][]const u8{ "sub_a.cmi", "sub_b.cmi", "packed.cmi" }) |f| {
        Dir.cwd().deleteFile(io, try std.fs.path.join(arena, &.{ work_dir, f })) catch {};
    }

    const native_pack_obj: []const u8 = if (!job.target.isLinux()) blk: {
        _ = try host.run("ocamlopt.opt", &.{ "-c", "sub_a.ml", "sub_b.ml", "packed.ml" });
        _ = try host.run("ocamlopt.opt", &.{ "-a", "-o", "packed_lib.cmxa", "sub_a.cmx", "sub_b.cmx", "packed.cmx" });
        break :blk "packed_lib.cmxa";
    } else blk: {
        _ = try host.run("ocamlopt.opt", &.{ "-for-pack", "Packed", "-c", "sub_a.ml", "sub_b.ml" });
        _ = try host.run("ocamlopt.opt", &.{ "-pack", "-o", "packed.cmx", "sub_a.cmx", "sub_b.cmx" });
        break :blk "packed.cmx";
    };

    _ = try host.run("ocamlc.opt", &.{ "-c", "calc_parser.mli", "calc_parser.ml", "calc_lexer.ml", "plugin_api.ml", "myplugin.ml" });

    const otherlibs_includes: []const []const u8 = &.{ "-I", "+unix", "-I", "+str", "-I", "+threads", "-I", "+runtime_events", "-I", "+dynlink" };
    const custom_byte_name = try std.fmt.allocPrint(arena, "test_custom_byte{s}", .{t_ext});
    _ = try host.run("ocamlc.opt", try std.mem.concat(arena, []const u8, &.{
        &.{ "-custom", "-g" },
        otherlibs_includes,
        &.{ "unix.cma", "str.cma", "threads.cma", "runtime_events.cma", "dynlink.cma" },
        &.{ "cstub_byt.o", "calc_parser.cmo", "calc_lexer.cmo", byte_pack_obj, "plugin_api.cmo", "main.ml", "-o", custom_byte_name },
    }));
    if (job.host.isWindows() and !job.target.isWindows()) {
        // `Bytelink.fix_exec_name` checks the host's `Sys.os_type` and appends
        // `.exe` to `-custom` outputs without an extension.
        const win_custom = try std.fs.path.join(arena, &.{ work_dir, "test_custom_byte.exe" });
        const dst_custom = try std.fs.path.join(arena, &.{ work_dir, custom_byte_name });
        if (!pathExists(io, dst_custom) and pathExists(io, win_custom)) {
            try Dir.cwd().rename(win_custom, Dir.cwd(), dst_custom, io);
        }
    }

    const pure_byte_name = try std.fmt.allocPrint(arena, "test_pure_byte{s}", .{t_ext});
    if (has_shared_libs) {
        _ = try host.runByte("ocamlmklib", &.{ "-o", "zcamlstub", "cstub_byt.o" });
        _ = try host.run("ocamlc.opt", try std.mem.concat(arena, []const u8, &.{
            &.{"-g"},
            otherlibs_includes,
            &.{ "unix.cma", "str.cma", "threads.cma", "runtime_events.cma", "dynlink.cma" },
            &.{ "-dllib", "-lzcamlstub", "calc_parser.cmo", "calc_lexer.cmo", byte_pack_obj, "plugin_api.cmo", "main.ml", "-o", pure_byte_name },
        }));
    }

    _ = try host.run("ocamlopt.opt", &.{ "-c", "calc_parser.ml", "calc_lexer.ml", "plugin_api.ml" });
    if (has_natdynlink) _ = try host.run("ocamlopt.opt", &.{ "-shared", "myplugin.ml", "-o", "myplugin.cmxs" });

    const nat_exe_name = try std.fmt.allocPrint(arena, "test_native_opt{s}", .{t_ext});
    _ = try host.run("ocamlopt.opt", try std.mem.concat(arena, []const u8, &.{
        &.{"-g"},
        otherlibs_includes,
        &.{ "unix.cmxa", "str.cmxa", "threads.cmxa", "runtime_events.cmxa", "dynlink.cmxa" },
        &.{ "cstub_nat.o", "calc_parser.cmx", "calc_lexer.cmx", native_pack_obj, "plugin_api.cmx", "main.ml", "-o", nat_exe_name },
    }));

    _ = try host.run("ocamlobjinfo.opt", &.{ byte_pack_obj, native_pack_obj });

    if (canRun(job.target, cur, true)) {
        try runTargetBinaries(ctx, arena, job.target, bin_dir, stublibs_dir, work_dir, has_shared_libs, has_natdynlink);
        return "PASSED (compiled & executed)";
    }

    const deferred_root = ctx.save_deferred_abs orelse return "COMPILED (target OS not runnable here)";
    const bundle_name = try std.fmt.allocPrint(arena, "host-{s}__target-{s}", .{ job.host.raw, job.target.raw });
    const bundle_dir = try std.fs.path.join(arena, &.{ deferred_root, bundle_name });
    try Dir.cwd().createDirPath(io, bundle_dir);

    for ([_][]const u8{
        custom_byte_name,
        pure_byte_name,
        "myplugin.cmo",
        nat_exe_name,
        "myplugin.cmxs",
        "dllzcamlstub.so",
        "dllzcamlstub.dll",
    }) |f| {
        const src_f = try std.fs.path.join(arena, &.{ work_dir, f });
        if (pathExists(io, src_f)) {
            _ = try Dir.cwd().updateFile(io, src_f, Dir.cwd(), try std.fs.path.join(arena, &.{ bundle_dir, f }), .{});
        }
    }
    const rt_src = try targetOcamlrun(io, arena, bin_dir, t_ext);
    if (pathExists(io, rt_src)) {
        const rt_dst = try std.fs.path.join(arena, &.{ bundle_dir, try std.fmt.allocPrint(arena, "ocamlrun-target{s}", .{t_ext}) });
        _ = try Dir.cwd().updateFile(io, rt_src, Dir.cwd(), rt_dst, .{});
    }
    if (pathExists(io, stublibs_dir)) {
        const dst_stublibs = try std.fs.path.join(arena, &.{ bundle_dir, "stublibs" });
        try Dir.cwd().createDirPath(io, dst_stublibs);
        try copyDirFiles(io, arena, stublibs_dir, dst_stublibs);
    }
    return "COMPILED (deferred bundle saved)";
}

/// Runs the installed host tools in the work directory.
const Host = struct {
    ctx: *Context,
    arena: Allocator,
    wrap: ExecWrapper,
    bin_dir: []const u8,
    triple: Triple,
    cwd: []const u8,

    fn run(self: Host, tool: []const u8, args: []const []const u8) ![]const u8 {
        return self.runTool(tool, false, args);
    }

    /// Bytecode executables are `#!` scripts on Unix hosts: run them with `ocamlrun`.
    fn runByte(self: Host, tool: []const u8, args: []const []const u8) ![]const u8 {
        return self.runTool(tool, !self.triple.isWindows(), args);
    }

    fn runTool(self: Host, tool: []const u8, via_ocamlrun: bool, args: []const []const u8) ![]const u8 {
        const ext = self.triple.exeExt();
        const tool_path = try std.fs.path.join(self.arena, &.{ self.bin_dir, try std.fmt.allocPrint(self.arena, "{s}{s}", .{ tool, ext }) });
        const ocamlrun = try std.fs.path.join(self.arena, &.{ self.bin_dir, try std.fmt.allocPrint(self.arena, "ocamlrun{s}", .{ext}) });
        const argv = try std.mem.concat(self.arena, []const u8, &.{
            self.wrap.prefix_argv,
            if (via_ocamlrun) &.{ ocamlrun, tool_path } else &.{tool_path},
            args,
        });
        return runChecked(self.ctx, self.arena, argv, self.cwd, &self.wrap.env, tool);
    }
};

/// Run the fixture executables in `work_dir` (built by `verifyPair`, or a deferred bundle)
/// and check that they print `ZCAML_VERIFY_OK`.
fn runTargetBinaries(
    ctx: *Context,
    arena: Allocator,
    target: Triple,
    bin_dir: []const u8,
    stublibs_dir: []const u8,
    work_dir: []const u8,
    has_shared_libs: bool,
    has_natdynlink: bool,
) !void {
    const io = ctx.init.io;
    const t_ext = target.exeExt();

    var wrap = try buildExecWrapper(ctx, arena, target, &.{ stublibs_dir, work_dir });
    const caml_ld = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
        work_dir,
        @as(u8, if (target.isWindows()) ';' else ':'),
        stublibs_dir,
    });
    try wrap.env.put("CAML_LD_LIBRARY_PATH", caml_ld);
    if (target.isMacos()) try wrap.env.put("DYLD_LIBRARY_PATH", caml_ld);

    const Check = struct { desc: []const u8, argv: []const []const u8 };
    var checks: std.ArrayList(Check) = .empty;

    const pure_byte_name = try std.fmt.allocPrint(arena, "test_pure_byte{s}", .{t_ext});
    if (has_shared_libs and pathExists(io, try std.fs.path.join(arena, &.{ work_dir, pure_byte_name }))) {
        try checks.append(arena, .{
            .desc = "run pure bytecode",
            .argv = try arena.dupe([]const u8, &.{ try targetOcamlrun(io, arena, bin_dir, t_ext), pure_byte_name, "myplugin.cmo" }),
        });
    }
    try checks.append(arena, .{
        .desc = "run custom bytecode",
        .argv = try arena.dupe([]const u8, &.{ try std.fs.path.join(arena, &.{ work_dir, try std.fmt.allocPrint(arena, "test_custom_byte{s}", .{t_ext}) }), "myplugin.cmo" }),
    });
    const nat_exe_path = try std.fs.path.join(arena, &.{ work_dir, try std.fmt.allocPrint(arena, "test_native_opt{s}", .{t_ext}) });
    try checks.append(arena, .{
        .desc = "run native executable",
        .argv = try arena.dupe([]const u8, if (has_natdynlink and pathExists(io, try std.fs.path.join(arena, &.{ work_dir, "myplugin.cmxs" })))
            &.{ nat_exe_path, "myplugin.cmxs" }
        else
            &.{nat_exe_path}),
    });

    for (checks.items) |check| {
        const argv = try std.mem.concat(arena, []const u8, &.{ wrap.prefix_argv, check.argv });
        const out = try runChecked(ctx, arena, argv, work_dir, &wrap.env, check.desc);
        if (std.mem.indexOf(u8, out, "ZCAML_VERIFY_OK") == null) return error.VerifyOutputMismatch;
    }
}

fn runDeferredBundles(ctx: *Context, deferred_root: []const u8) !void {
    const io = ctx.init.io;
    const arena = ctx.init.arena.allocator();
    const cur = currentMachineTriple();

    var failures: usize = 0;
    for (try listDirs(io, arena, deferred_root, "host-")) |bname| {
        const sep_idx = std.mem.indexOf(u8, bname, "__target-") orelse continue;
        const host = Triple.parse(bname["host-".len..sep_idx]);
        const target = Triple.parse(bname[sep_idx + "__target-".len ..]);
        if (!canRun(target, cur, true)) continue;

        const bundle_dir = try std.fs.path.join(arena, &.{ deferred_root, bname });
        const stublibs_dir = try std.fs.path.join(arena, &.{ bundle_dir, "stublibs" });
        const t0 = Io.Clock.awake.now(io);
        const label = try std.fmt.allocPrint(arena, "{s} -> {s} (deferred)", .{ host.shortName(arena), target.shortName(arena) });

        if (runTargetBinaries(ctx, arena, target, bundle_dir, stublibs_dir, bundle_dir, true, !target.isWindows())) {
            const dt = t0.untilNow(io, .awake);
            std.debug.print("  [OK]   {s:<45} ({f}) PASSED (deferred execution)\n", .{ label, dt });
        } else |err| {
            failures += 1;
            std.debug.print("  [FAIL] {s}: {t}\n", .{ label, err });
        }
    }
    if (failures > 0) std.process.exit(1);
}

fn runChecked(
    ctx: *Context,
    arena: Allocator,
    argv: []const []const u8,
    cwd_path: []const u8,
    env: *const std.process.Environ.Map,
    step_desc: []const u8,
) ![]const u8 {
    const io = ctx.init.io;
    const gpa = ctx.init.gpa;
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .environ_map = env,
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    if (!res.term.success()) {
        ctx.print_mutex.lockUncancelable(io);
        defer ctx.print_mutex.unlock(io);
        const joined = std.mem.join(arena, " ", argv) catch "";
        std.debug.print(
            "\n[{s}] Command failed ({f}):\n  cwd: {s}\n  cmd: {s}\n  stdout: {s}\n  stderr: {s}\n",
            .{ step_desc, res.term, cwd_path, joined, res.stdout, res.stderr },
        );
        return error.CommandFailed;
    }
    return try arena.dupe(u8, res.stdout);
}

/// How to run an executable for `triple` on this machine.
const ExecWrapper = struct {
    prefix_argv: []const []const u8,
    env: std.process.Environ.Map,
};

fn buildExecWrapper(
    ctx: *Context,
    arena: Allocator,
    triple: Triple,
    extra_dll_dirs: []const []const u8,
) !ExecWrapper {
    const cur = currentMachineTriple();
    var env = try ctx.init.environ_map.clone(arena);

    if (triple.isWindows()) {
        if (cur.isWindows()) return .{ .prefix_argv = &.{}, .env = env };
        try env.put("WINEDEBUG", "-all");
        var wine_paths: std.ArrayList(u8) = .empty;
        for (extra_dll_dirs) |d| {
            if (wine_paths.items.len > 0) try wine_paths.append(arena, ';');
            try wine_paths.print(arena, "Z:{s}", .{d});
        }
        if (wine_paths.items.len > 0) try env.put("WINEPATH", wine_paths.items);
        return .{ .prefix_argv = &.{"wine"}, .env = env };
    }

    if (triple.isMacos()) {
        if (std.mem.eql(u8, cur.arch, "aarch64") and std.mem.eql(u8, triple.arch, "x86_64")) {
            return .{ .prefix_argv = &.{ "arch", "-x86_64" }, .env = env };
        }
        return .{ .prefix_argv = &.{}, .env = env };
    }

    if (triple.isLinux()) {
        const sysroot_opt = try ensureSysroot(ctx.init, ctx.cache_dir, triple);
        if (!std.mem.eql(u8, triple.arch, cur.arch)) {
            const sysroot = sysroot_opt orelse return error.MissingSysroot;
            return .{ .prefix_argv = try arena.dupe([]const u8, &.{ qemuBinForArch(triple.arch), "-L", sysroot }), .env = env };
        }
        if (triple.isMusl()) if (sysroot_opt) |sysroot| if (!std.mem.eql(u8, sysroot, "/")) {
            // Not the loader directly: `/proc/self/exe` and `argv[0]` must remain the
            // program itself (relocatable stdlib discovery, `-custom` bytecode reading itself).
            return .{ .prefix_argv = try arena.dupe([]const u8, &.{ "qemu-x86_64", "-L", sysroot }), .env = env };
        };
        return .{ .prefix_argv = &.{}, .env = env };
    }

    return error.UnsupportedTriple;
}

/// The root to run `target` executables from with QEMU, `"/"` for the system one,
/// or `null` when they run natively.
fn ensureSysroot(init: std.process.Init, cache_dir: []const u8, target: Triple) !?[]const u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cur = currentMachineTriple();

    if (!target.isLinux()) return null;
    if (std.mem.eql(u8, target.arch, cur.arch) and !target.isMusl()) return null;

    const sysroot = try std.fs.path.join(arena, &.{ cache_dir, "sysroots", target.raw });

    if (target.isMusl()) {
        const sys_loader = try std.fmt.allocPrint(arena, "/lib/ld-musl-{s}.so.1", .{target.arch});
        if (pathExists(io, sys_loader) and std.mem.eql(u8, target.arch, cur.arch)) return "/";

        const ready = try std.fs.path.join(arena, &.{ sysroot, ".musl-1.2.5-r13-ready" });
        const loader = try std.fmt.allocPrint(arena, "{s}/lib/ld-musl-{s}.so.1", .{ sysroot, target.arch });
        if (pathExists(io, ready) and pathExists(io, loader)) return sysroot;

        const apk_arch = for (musl_apks) |m| {
            if (std.mem.eql(u8, m.arch, target.arch)) break m.apk_arch;
        } else return error.UnsupportedMuslArch;

        std.debug.print("==> Downloading Alpine musl loader for {s}...\n", .{target.raw});
        const usr_lib = try std.fs.path.join(arena, &.{ sysroot, "usr", "lib" });
        try Dir.cwd().createDirPath(io, usr_lib);

        const apk_path = try std.fs.path.join(arena, &.{ sysroot, "musl-1.2.5-r13.apk" });
        const url = try std.fmt.allocPrint(arena, "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/{s}/musl-1.2.5-r13.apk", .{apk_arch});
        const dl = try std.process.run(gpa, io, .{ .argv = &.{ "curl", "-fsSL", url, "-o", apk_path } });
        gpa.free(dl.stdout);
        gpa.free(dl.stderr);
        if (!dl.term.success()) return error.DownloadFailed;

        const member = try std.fmt.allocPrint(arena, "lib/ld-musl-{s}.so.1", .{target.arch});
        const ex = try std.process.run(gpa, io, .{
            .argv = &.{ "tar", "--ignore-zeros", "--warning=no-unknown-keyword", "-xOzf", apk_path, member },
        });
        defer gpa.free(ex.stdout);
        defer gpa.free(ex.stderr);
        if (!ex.term.success()) return error.ExtractFailed;

        try Dir.cwd().writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(arena, "{s}/ld-musl-{s}.so.1", .{ usr_lib, target.arch }),
            .data = ex.stdout,
            .flags = .{ .permissions = .executable_file },
        });

        const lib_link = try std.fs.path.join(arena, &.{ sysroot, "lib" });
        if (!pathExists(io, lib_link)) {
            Dir.cwd().symLink(io, "usr/lib", lib_link, .{ .is_directory = true }) catch {};
        }
        try Dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "" });
        return sysroot;
    }

    // Foreign glibc: prefer Ubuntu's cross libc in /usr/<arch>-linux-gnu.
    const multiarch = try std.fmt.allocPrint(arena, "/usr/{s}-linux-gnu", .{target.arch});
    if (pathExists(io, try std.fmt.allocPrint(arena, "{s}/lib/libc.so.6", .{multiarch}))) return multiarch;

    if (pathExists(io, try std.fs.path.join(arena, &.{ sysroot, ".ready-v2" }))) return sysroot;

    const deb_arch = debianArchForTarget(target.raw);
    std.debug.print("==> Downloading Debian stable glibc sysroot ({s}) for {s}...\n", .{ deb_arch, target.raw });
    try Dir.cwd().createDirPath(io, sysroot);

    const script = try std.fmt.allocPrint(
        arena,
        \\set -euo pipefail
        \\cd "{s}"
        \\curl -fsSL "https://deb.debian.org/debian/dists/stable/main/binary-{s}/Packages.gz" -o Packages.gz
        \\for pkg in libc6 libgcc-s1; do
        \\  rel_url="$(zcat Packages.gz | awk -v p="$pkg" '$0 == "Package: " p {{flag=1}} flag && /^Filename:/ {{print $2; exit}}' || true)"
        \\  curl -fsSL "https://deb.debian.org/debian/$rel_url" -o "${{pkg}}.deb"
        \\  data_member="$(ar t "${{pkg}}.deb" | grep '^data\.tar')"
        \\  case "$data_member" in
        \\    *.xz)  ar p "${{pkg}}.deb" "$data_member" | tar -xJ ;;
        \\    *.zst) ar p "${{pkg}}.deb" "$data_member" | tar --zstd -x ;;
        \\    *.gz)  ar p "${{pkg}}.deb" "$data_member" | tar -xz ;;
        \\  esac
        \\  rm -f "${{pkg}}.deb"
        \\done
        \\rm -f Packages.gz
        \\mkdir -p usr/lib
        \\for d in lib lib64 usr/lib64; do
        \\  if [[ -d "$d" && ! -L "$d" ]]; then
        \\    cp -a "$d"/. usr/lib/
        \\    rm -rf "$d"
        \\  fi
        \\done
        \\ln -sfn usr/lib lib
        \\ln -sfn usr/lib lib64
        \\touch .ready-v2
    ,
        .{ sysroot, deb_arch },
    );
    const res = try std.process.run(gpa, io, .{ .argv = &.{ "bash", "-c", script } });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.term.success()) return error.DebianSysrootFailed;
    return sysroot;
}

const musl_apks = [_]struct { arch: []const u8, apk_arch: []const u8 }{
    .{ .arch = "x86_64", .apk_arch = "x86_64" },
    .{ .arch = "aarch64", .apk_arch = "aarch64" },
    .{ .arch = "riscv64", .apk_arch = "riscv64" },
    .{ .arch = "powerpc64le", .apk_arch = "ppc64le" },
    .{ .arch = "s390x", .apk_arch = "s390x" },
};

fn qemuBinForArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "aarch64")) return "qemu-aarch64";
    if (std.mem.eql(u8, arch, "riscv64")) return "qemu-riscv64";
    if (std.mem.eql(u8, arch, "powerpc64le")) return "qemu-ppc64le";
    if (std.mem.eql(u8, arch, "s390x")) return "qemu-s390x";
    std.debug.panic("Unsupported foreign Linux arch for QEMU: {s}", .{arch});
}

fn debianArchForTarget(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "aarch64-linux-gnu")) return "arm64";
    if (std.mem.eql(u8, raw, "riscv64-linux-gnu")) return "riscv64";
    if (std.mem.eql(u8, raw, "powerpc64le-linux-gnu")) return "ppc64el";
    if (std.mem.eql(u8, raw, "s390x-linux-gnu")) return "s390x";
    std.debug.panic("Unsupported foreign glibc target: {s}", .{raw});
}

fn initWinePrefix(init: std.process.Init) void {
    const io = init.io;
    const gpa = init.gpa;
    var env = init.environ_map.clone(gpa) catch return;
    defer env.deinit();
    env.put("WINEDEBUG", "-all") catch return;
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "wine", "wineboot", "--init" },
        .environ_map = &env,
    }) catch return;
    gpa.free(res.stdout);
    gpa.free(res.stderr);
}

/// `<arch>-<os>-<abi>`, as in the install layout (`host-x86_64-linux-gnu`).
const Triple = struct {
    raw: []const u8,
    arch: []const u8,
    os: []const u8,
    abi: []const u8,

    fn parse(raw: []const u8) Triple {
        var it = std.mem.splitScalar(u8, raw, '-');
        const arch = it.next() orelse raw;
        const os = it.next() orelse "unknown";
        const abi = it.next() orelse "none";
        return .{ .raw = raw, .arch = arch, .os = os, .abi = abi };
    }

    fn isWindows(self: Triple) bool {
        return std.mem.eql(u8, self.os, "windows");
    }

    fn isMacos(self: Triple) bool {
        return std.mem.eql(u8, self.os, "macos");
    }

    fn isLinux(self: Triple) bool {
        return std.mem.eql(u8, self.os, "linux");
    }

    fn isMusl(self: Triple) bool {
        return std.mem.eql(u8, self.abi, "musl");
    }

    fn exeExt(self: Triple) []const u8 {
        return if (self.isWindows()) ".exe" else "";
    }

    /// `aarch64-macos-none` -> `aarch64-macos`
    fn shortName(self: Triple, arena: Allocator) []const u8 {
        if (self.isMacos() and std.mem.eql(u8, self.abi, "none")) {
            return std.fmt.allocPrint(arena, "{s}-macos", .{self.arch}) catch @panic("OOM");
        }
        return self.raw;
    }

    fn eql(a: Triple, b: Triple) bool {
        return std.mem.eql(u8, a.raw, b.raw);
    }

    fn matchesFilter(self: Triple, arena: Allocator, filter: ?[]const u8) bool {
        const f = filter orelse return true;
        return std.mem.eql(u8, self.raw, f) or std.mem.eql(u8, self.shortName(arena), f);
    }
};

fn currentMachineTriple() Triple {
    const arch = @tagName(builtin.cpu.arch);
    return switch (builtin.os.tag) {
        .macos => .{ .raw = arch ++ "-macos-none", .arch = arch, .os = "macos", .abi = "none" },
        .linux => .{ .raw = arch ++ "-linux-gnu", .arch = arch, .os = "linux", .abi = "gnu" },
        .windows => .{ .raw = arch ++ "-windows-gnu", .arch = arch, .os = "windows", .abi = "gnu" },
        else => @compileError("Unsupported host OS"),
    };
}

/// Whether `t` executables can run on `cur`: Linux runs every Linux arch with QEMU
/// (and Windows with Wine, if allowed); Apple Silicon also runs x86_64 with Rosetta.
fn canRun(t: Triple, cur: Triple, wine: bool) bool {
    const same_arch = std.mem.eql(u8, t.arch, cur.arch);
    if (cur.isLinux()) return t.isLinux() or (wine and t.isWindows());
    if (cur.isMacos()) return t.isMacos() and (same_arch or
        (std.mem.eql(u8, cur.arch, "aarch64") and std.mem.eql(u8, t.arch, "x86_64")));
    if (cur.isWindows()) return t.isWindows() and same_arch;
    return t.eql(cur);
}

fn usesWine(target: Triple, cur: Triple) bool {
    return cur.isLinux() and target.isWindows();
}

/// `ocamlrun-target` when cross compiling, else `ocamlrun`.
fn targetOcamlrun(io: Io, arena: Allocator, bin_dir: []const u8, t_ext: []const u8) ![]const u8 {
    const cross = try std.fs.path.join(arena, &.{ bin_dir, try std.fmt.allocPrint(arena, "ocamlrun-target{s}", .{t_ext}) });
    if (pathExists(io, cross)) return cross;
    return std.fs.path.join(arena, &.{ bin_dir, try std.fmt.allocPrint(arena, "ocamlrun{s}", .{t_ext}) });
}

/// Names of the subdirectories of `dir_abs` starting with `prefix`, sorted.
fn listDirs(io: Io, arena: Allocator, dir_abs: []const u8, prefix: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = try Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, prefix)) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.items;
}

fn copyDirFiles(io: Io, arena: Allocator, src_abs: []const u8, dst_abs: []const u8) !void {
    var dir = try Dir.openDirAbsolute(io, src_abs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const src = try std.fs.path.join(arena, &.{ src_abs, entry.name });
        const dst = try std.fs.path.join(arena, &.{ dst_abs, entry.name });
        _ = try Dir.cwd().updateFile(io, src, Dir.cwd(), dst, .{});
    }
}

fn pathExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
