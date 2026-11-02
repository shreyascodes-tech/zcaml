const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");
const InputDir = utils.InputDir;

root_dir: []const u8,
fixtures_dir: InputDir,
cache_dir: ?[]const u8 = null,
host: ?[]const u8 = null,
target: ?[]const u8 = null,
jobs: usize = 8,
save_deferred: ?[]const u8 = null,
run_deferred: ?[]const u8 = null,

const VerifyToolchains = @This();

const MuslInfo = struct {
    arch: []const u8,
    apk_arch: []const u8,
    sha256: []const u8,
};

const musl_infos = [_]MuslInfo{
    .{ .arch = "x86_64", .apk_arch = "x86_64", .sha256 = "359890bc7c4dc5fee7a85192de60a471c987e4664767288578beca60a44db2c8" },
    .{ .arch = "aarch64", .apk_arch = "aarch64", .sha256 = "d616c430bcbe0bf452b7f6ea2669f2cad14e85644a7599f4f495115d021742ef" },
    .{ .arch = "riscv64", .apk_arch = "riscv64", .sha256 = "27760752b676b78f1edca22b7d933515ea9ed3596bb7378da8d2bb81c873a3e6" },
    .{ .arch = "powerpc64le", .apk_arch = "ppc64le", .sha256 = "cbc140f849bee3036efc89735c4d312ae0f23f1abe6c42d7f23d557c85ed3e01" },
    .{ .arch = "s390x", .apk_arch = "s390x", .sha256 = "a7bd3c2aacd4e75d642eb5e40f65ca7925efaac98134fa52f4c9b070cdf6c366" },
};

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

fn canExecuteHostOnCurrentMachine(h: Triple, cur: Triple) bool {
    if (cur.isLinux()) {
        return h.isLinux();
    }
    if (cur.isMacos()) {
        if (!h.isMacos()) return false;
        if (std.mem.eql(u8, cur.arch, "aarch64")) {
            return std.mem.eql(u8, h.arch, "aarch64") or std.mem.eql(u8, h.arch, "x86_64");
        }
        return std.mem.eql(u8, h.arch, cur.arch);
    }
    if (cur.isWindows()) {
        return h.isWindows() and std.mem.eql(u8, h.arch, cur.arch);
    }
    return h.eql(cur);
}

fn canExecuteTargetOnCurrentMachine(t: Triple, cur: Triple) bool {
    if (cur.isLinux()) {
        return t.isLinux() or t.isWindows();
    }
    if (cur.isMacos()) {
        if (!t.isMacos()) return false;
        if (std.mem.eql(u8, cur.arch, "aarch64")) {
            return std.mem.eql(u8, t.arch, "aarch64") or std.mem.eql(u8, t.arch, "x86_64");
        }
        return std.mem.eql(u8, t.arch, cur.arch);
    }
    if (cur.isWindows()) {
        return t.isWindows() and std.mem.eql(u8, t.arch, cur.arch);
    }
    return t.eql(cur);
}

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

fn pathExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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

pub fn run(self: *VerifyToolchains, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const cur = currentMachineTriple();
    const cache_dir = if (self.cache_dir) |c|
        try Dir.cwd().realPathFileAlloc(io, c, arena)
    else blk: {
        if (init.environ_map.get("XDG_CACHE_HOME")) |xdg| {
            break :blk try std.fs.path.join(arena, &.{ xdg, "zcaml" });
        }
        if (init.environ_map.get("LOCALAPPDATA")) |appdata| {
            break :blk try std.fs.path.join(arena, &.{ appdata, "zcaml" });
        }
        const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/tmp";
        break :blk try std.fs.path.join(arena, &.{ home, ".cache", "zcaml" });
    };
    try Dir.cwd().createDirPath(io, cache_dir);

    const fixtures_abs = try Dir.cwd().realPathFileAlloc(io, self.fixtures_dir.path(), arena);
    const save_deferred_abs: ?[]const u8 = if (self.save_deferred) |sd| blk: {
        try Dir.cwd().createDirPath(io, sd);
        break :blk try Dir.cwd().realPathFileAlloc(io, sd, arena);
    } else null;

    if (self.run_deferred) |rd| {
        try Dir.cwd().createDirPath(io, rd);
        const rd_abs = try Dir.cwd().realPathFileAlloc(io, rd, arena);
        return runDeferredBundles(init, cache_dir, fixtures_abs, rd_abs, self.jobs);
    }

    const root_abs = try Dir.cwd().realPathFileAlloc(io, self.root_dir, arena);
    const jobs = try discoverPairs(io, arena, root_abs, self.host, self.target);

    var runnable: std.ArrayList(PairJob) = .empty;
    var skipped_count: usize = 0;
    for (jobs) |job| {
        if (canExecuteHostOnCurrentMachine(job.host, cur)) {
            try runnable.append(arena, job);
        } else {
            skipped_count += 1;
        }
    }

    std.debug.print(
        "==> Running zcaml toolchain verification on {s} ({d} runnable, {d} for other host OS, jobs={d})\n",
        .{ cur.raw, runnable.items.len, skipped_count, self.jobs },
    );

    // Pre-provision sysroots and Wine prefix sequentially before parallel execution
    var needed_sysroots: std.StringHashMapUnmanaged(Triple) = .empty;
    var needs_wine = false;
    for (runnable.items) |job| {
        if (job.host.isLinux()) try needed_sysroots.put(arena, job.host.raw, job.host);
        if (job.target.isLinux() and canExecuteTargetOnCurrentMachine(job.target, cur)) {
            try needed_sysroots.put(arena, job.target.raw, job.target);
        }
        if (cur.isLinux() and job.target.isWindows() and canExecuteTargetOnCurrentMachine(job.target, cur)) {
            needs_wine = true;
        }
    }

    var sys_it = needed_sysroots.valueIterator();
    while (sys_it.next()) |t| {
        _ = try ensureSysroot(init, cache_dir, t.*);
    }

    if (needs_wine) {
        initWinePrefix(init);
    }

    var ctx: Context = .{
        .init = init,
        .cache_dir = cache_dir,
        .fixtures_abs = fixtures_abs,
        .save_deferred_abs = save_deferred_abs,
    };

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

        if (verifySinglePair(ctx, arena, job)) |status| {
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

fn discoverPairs(
    io: Io,
    arena: Allocator,
    root_abs: []const u8,
    host_filter: ?[]const u8,
    target_filter: ?[]const u8,
) ![]PairJob {
    var host_names: std.ArrayList([]const u8) = .empty;
    {
        var root_dir = try Dir.openDirAbsolute(io, root_abs, .{ .iterate = true });
        defer root_dir.close(io);
        var it = root_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "host-")) {
                try host_names.append(arena, try arena.dupe(u8, entry.name));
            }
        }
    }
    std.mem.sort([]const u8, host_names.items, {}, strLessThan);

    var jobs: std.ArrayList(PairJob) = .empty;
    for (host_names.items) |h_name| {
        const host = Triple.parse(h_name["host-".len..]);
        if (!host.matchesFilter(arena, host_filter)) continue;

        const host_abs = try std.fs.path.join(arena, &.{ root_abs, h_name });
        var target_names: std.ArrayList([]const u8) = .empty;
        {
            var h_dir = try Dir.openDirAbsolute(io, host_abs, .{ .iterate = true });
            defer h_dir.close(io);
            var it = h_dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "target-")) {
                    try target_names.append(arena, try arena.dupe(u8, entry.name));
                }
            }
        }
        std.mem.sort([]const u8, target_names.items, {}, strLessThan);

        for (target_names.items) |t_name| {
            const target = Triple.parse(t_name["target-".len..]);
            if (!target.matchesFilter(arena, target_filter)) continue;
            const prefix_abs = try std.fs.path.join(arena, &.{ host_abs, t_name });
            try jobs.append(arena, .{
                .prefix_abs = prefix_abs,
                .host = host,
                .target = target,
            });
        }
    }
    return jobs.items;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

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
        if (cur.isWindows()) {
            return .{ .prefix_argv = &.{}, .env = env };
        }
        try env.put("WINEDEBUG", "-all");
        var wine_paths: std.ArrayList(u8) = .empty;
        for (extra_dll_dirs) |d| {
            if (wine_paths.items.len > 0) try wine_paths.append(arena, ';');
            try wine_paths.print(arena, "Z:{s}", .{d});
        }
        if (wine_paths.items.len > 0) {
            try env.put("WINEPATH", wine_paths.items);
        }
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
        if (std.mem.eql(u8, triple.arch, cur.arch)) {
            if (triple.isMusl()) {
                if (sysroot_opt) |sysroot| {
                    if (!std.mem.eql(u8, sysroot, "/")) {
                        // Use qemu-x86_64 -L <sysroot> so `/proc/self/exe` and `argv[0]` remain the actual
                        // target binary (important for OCaml's relocatable stdlib discovery and `-custom`
                        // bytecode self-reading).
                        return .{
                            .prefix_argv = try arena.dupe([]const u8, &.{ "qemu-x86_64", "-L", sysroot }),
                            .env = env,
                        };
                    }
                }
            }
            return .{ .prefix_argv = &.{}, .env = env };
        } else {
            const sysroot = sysroot_opt orelse return error.MissingSysroot;
            const qemu_bin = qemuBinForArch(triple.arch);
            return .{
                .prefix_argv = try arena.dupe([]const u8, &.{ qemu_bin, "-L", sysroot }),
                .env = env,
            };
        }
    }

    return error.UnsupportedTriple;
}

fn verifySinglePair(ctx: *Context, arena: Allocator, job: PairJob) ![]const u8 {
    const io = ctx.init.io;
    const cur = currentMachineTriple();

    // Serialize Wine invocations so concurrent wineserver operations don't race
    const uses_wine = cur.isLinux() and job.target.isWindows() and canExecuteTargetOnCurrentMachine(job.target, cur);
    if (uses_wine) ctx.wine_mutex.lockUncancelable(io);
    defer if (uses_wine) ctx.wine_mutex.unlock(io);

    var rand_int: u64 = undefined;
    io.random(@ptrCast(&rand_int));
    const rand_hex = std.fmt.hex(rand_int);

    const tmp_base = ctx.init.environ_map.get("RUNNER_TEMP") orelse
        ctx.init.environ_map.get("TEMP") orelse
        ctx.init.environ_map.get("TMP") orelse
        "/tmp";
    const work_dir_path = try std.fs.path.join(arena, &.{
        tmp_base,
        try std.fmt.allocPrint(
            arena,
            "zcaml-verify-{s}-{s}-{s}",
            .{ job.host.shortName(arena), job.target.shortName(arena), rand_hex },
        ),
    });
    try Dir.cwd().createDirPath(io, work_dir_path);
    defer Dir.cwd().deleteTree(io, work_dir_path) catch {};

    // Copy fixture files into work_dir_path
    const fixture_files = [_][]const u8{
        "cstub.c",
        "calc_parser.mly",
        "calc_lexer.mll",
        "sub_a.ml",
        "sub_b.ml",
        "packed.ml",
        "plugin_api.ml",
        "myplugin.ml",
        "main.ml",
    };
    for (fixture_files) |fname| {
        const src_p = try std.fs.path.join(arena, &.{ ctx.fixtures_abs, fname });
        const dst_p = try std.fs.path.join(arena, &.{ work_dir_path, fname });
        _ = try Dir.cwd().updateFile(io, src_p, Dir.cwd(), dst_p, .{});
    }

    const bin_dir = try std.fs.path.join(arena, &.{ job.prefix_abs, "bin" });
    const lib_dir = try std.fs.path.join(arena, &.{ job.prefix_abs, "lib", "ocaml" });
    const stublibs_dir = try std.fs.path.join(arena, &.{ lib_dir, "stublibs" });

    var host_wrap = try buildExecWrapper(ctx, arena, job.host, &.{stublibs_dir});
    const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const parent_path = ctx.init.environ_map.get("PATH") orelse "/usr/bin:/bin";
    const new_path = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{ bin_dir, path_sep, parent_path });
    try host_wrap.env.put("PATH", new_path);

    const h_ext = job.host.exeExt();
    const t_ext = job.target.exeExt();

    // 1. Verify ocamlc.opt -config
    const cfg_out = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{"-config"}),
        work_dir_path,
        &host_wrap.env,
        "ocamlc.opt -config",
    );
    const has_natdynlink = std.mem.indexOf(u8, cfg_out, "native_dynlink: true") != null;
    const has_shared_libs = std.mem.indexOf(u8, cfg_out, "supports_shared_libraries: true") != null;

    // 2. Smoke check compiler/tool binaries
    const ToolCheck = struct { name: []const u8, is_byte: bool };
    const tool_checks = [_]ToolCheck{
        .{ .name = "ocamlc.byte", .is_byte = true },
        .{ .name = "ocamlopt.byte", .is_byte = true },
        .{ .name = "ocamlopt.opt", .is_byte = false },
        .{ .name = "ocamllex.byte", .is_byte = true },
        .{ .name = "ocamllex.opt", .is_byte = false },
        .{ .name = "ocamldep.opt", .is_byte = false },
        .{ .name = "ocamlobjinfo.opt", .is_byte = false },
    };
    for (tool_checks) |tc| {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, tc.name, h_ext, tc.is_byte, job.host.isWindows(), &.{"-version"}),
            work_dir_path,
            &host_wrap.env,
            tc.name,
        );
    }
    if (job.host.eql(job.target)) {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamldoc.opt", h_ext, false, job.host.isWindows(), &.{"-version"}),
            work_dir_path,
            &host_wrap.env,
            "ocamldoc.opt -version",
        );
    }

    // 3. ocamlyacc & ocamllex
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlyacc", h_ext, false, job.host.isWindows(), &.{"calc_parser.mly"}),
        work_dir_path,
        &host_wrap.env,
        "ocamlyacc",
    );
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamllex.opt", h_ext, false, job.host.isWindows(), &.{"calc_lexer.mll"}),
        work_dir_path,
        &host_wrap.env,
        "ocamllex.opt",
    );

    // 4. Compile C stubs
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "cstub.c", "-o", "cstub_byt.o" }),
        work_dir_path,
        &host_wrap.env,
        "ocamlc -c cstub.c",
    );
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "cstub.c", "-o", "cstub_nat.o" }),
        work_dir_path,
        &host_wrap.env,
        "ocamlopt -c cstub.c",
    );

    // 5. Bytecode pack (sub_a + sub_b -> packed.cmo)
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "sub_a.ml", "sub_b.ml" }),
        work_dir_path,
        &host_wrap.env,
        "ocamlc sub_a sub_b",
    );
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{ "-pack", "-o", "packed.cmo", "sub_a.cmo", "sub_b.cmo" }),
        work_dir_path,
        &host_wrap.env,
        "ocamlc -pack",
    );
    const byte_pack_obj: []const u8 = if (!job.target.isLinux()) blk: {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "packed.ml" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlc packed.ml",
        );
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{ "-a", "-o", "packed_lib.cma", "sub_a.cmo", "sub_b.cmo", "packed.cmo" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlc -a packed_lib.cma",
        );
        break :blk "packed_lib.cma";
    } else "packed.cmo";

    for ([_][]const u8{ "sub_a.cmi", "sub_b.cmi", "packed.cmi" }) |f| {
        const p = try std.fs.path.join(arena, &.{ work_dir_path, f });
        Dir.cwd().deleteFile(io, p) catch {};
    }

    // Native pack (or archive on COFF/Mach-O where Zig's partial linker `ld -r` has relocation limitations)
    const native_pack_obj: []const u8 = if (!job.target.isLinux()) blk: {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "sub_a.ml", "sub_b.ml", "packed.ml" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlopt sub_a sub_b packed",
        );
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-a", "-o", "packed_lib.cmxa", "sub_a.cmx", "sub_b.cmx", "packed.cmx" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlopt -a packed_lib.cmxa",
        );
        break :blk "packed_lib.cmxa";
    } else blk: {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-for-pack", "Packed", "-c", "sub_a.ml", "sub_b.ml" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlopt -for-pack",
        );
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-pack", "-o", "packed.cmx", "sub_a.cmx", "sub_b.cmx" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlopt -pack",
        );
        break :blk "packed.cmx";
    };

    // 6. Compile modules & link custom bytecode, pure bytecode, and native executable
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "calc_parser.mli", "calc_parser.ml", "calc_lexer.ml", "plugin_api.ml", "myplugin.ml" }),
        work_dir_path,
        &host_wrap.env,
        "ocamlc modules",
    );

    const custom_byte_name = try std.fmt.allocPrint(arena, "test_custom_byte{s}", .{t_ext});
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{
            "-custom",
            "-g",
            "-I", "+unix",
            "-I", "+str",
            "-I", "+threads",
            "-I", "+runtime_events",
            "-I", "+dynlink",
            "unix.cma",
            "str.cma",
            "threads.cma",
            "runtime_events.cma",
            "dynlink.cma",
            "cstub_byt.o",
            "calc_parser.cmo",
            "calc_lexer.cmo",
            byte_pack_obj,
            "plugin_api.cmo",
            "main.ml",
            "-o",
            custom_byte_name,
        }),
        work_dir_path,
        &host_wrap.env,
        "ocamlc link custom bytecode",
    );
    if (job.host.isWindows() and !job.target.isWindows()) {
        // Upstream OCaml's `Bytelink.fix_exec_name` checks `Sys.os_type` (host OS)
        // and appends `.exe` when `-custom` is used and the output name has no `.`.
        const win_custom = try std.fs.path.join(arena, &.{ work_dir_path, "test_custom_byte.exe" });
        const dst_custom = try std.fs.path.join(arena, &.{ work_dir_path, custom_byte_name });
        if (!pathExists(io, dst_custom) and pathExists(io, win_custom)) {
            try Dir.cwd().rename(win_custom, Dir.cwd(), dst_custom, io);
        }
    }

    const pure_byte_name = try std.fmt.allocPrint(arena, "test_pure_byte{s}", .{t_ext});
    if (has_shared_libs) {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlmklib", h_ext, true, job.host.isWindows(), &.{ "-o", "zcamlstub", "cstub_byt.o" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlmklib zcamlstub",
        );
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlc.opt", h_ext, false, job.host.isWindows(), &.{
                "-g",
                "-I", "+unix",
                "-I", "+str",
                "-I", "+threads",
                "-I", "+runtime_events",
                "-I", "+dynlink",
                "unix.cma",
                "str.cma",
                "threads.cma",
                "runtime_events.cma",
                "dynlink.cma",
                "-dllib",
                "-lzcamlstub",
                "calc_parser.cmo",
                "calc_lexer.cmo",
                byte_pack_obj,
                "plugin_api.cmo",
                "main.ml",
                "-o",
                pure_byte_name,
            }),
            work_dir_path,
            &host_wrap.env,
            "ocamlc link pure bytecode",
        );
    }

    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-c", "calc_parser.ml", "calc_lexer.ml", "plugin_api.ml" }),
        work_dir_path,
        &host_wrap.env,
        "ocamlopt modules",
    );
    if (has_natdynlink) {
        _ = try runChecked(
            ctx,
            arena,
            try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{ "-shared", "myplugin.ml", "-o", "myplugin.cmxs" }),
            work_dir_path,
            &host_wrap.env,
            "ocamlopt -shared myplugin.cmxs",
        );
    }

    const nat_exe_name = try std.fmt.allocPrint(arena, "test_native_opt{s}", .{t_ext});
    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlopt.opt", h_ext, false, job.host.isWindows(), &.{
            "-g",
            "-I", "+unix",
            "-I", "+str",
            "-I", "+threads",
            "-I", "+runtime_events",
            "-I", "+dynlink",
            "unix.cmxa",
            "str.cmxa",
            "threads.cmxa",
            "runtime_events.cmxa",
            "dynlink.cmxa",
            "cstub_nat.o",
            "calc_parser.cmx",
            "calc_lexer.cmx",
            native_pack_obj,
            "plugin_api.cmx",
            "main.ml",
            "-o",
            nat_exe_name,
        }),
        work_dir_path,
        &host_wrap.env,
        "ocamlopt link native executable",
    );

    _ = try runChecked(
        ctx,
        arena,
        try toolCmd(arena, host_wrap.prefix_argv, bin_dir, "ocamlobjinfo.opt", h_ext, false, job.host.isWindows(), &.{ byte_pack_obj, native_pack_obj }),
        work_dir_path,
        &host_wrap.env,
        "ocamlobjinfo.opt",
    );

    // 7. Execute on target (or save deferred bundle if target OS is different)
    if (canExecuteTargetOnCurrentMachine(job.target, cur)) {
        try executeTargetBinaries(
            ctx,
            arena,
            job.target,
            bin_dir,
            stublibs_dir,
            work_dir_path,
            has_shared_libs,
            has_natdynlink,
        );
        return "PASSED (compiled & executed)";
    }

    if (ctx.save_deferred_abs) |deferred_root| {
        const bundle_name = try std.fmt.allocPrint(arena, "host-{s}__target-{s}", .{ job.host.raw, job.target.raw });
        const bundle_dir = try std.fs.path.join(arena, &.{ deferred_root, bundle_name });
        try Dir.cwd().createDirPath(io, bundle_dir);

        const to_copy = [_][]const u8{
            custom_byte_name,
            pure_byte_name,
            "myplugin.cmo",
            nat_exe_name,
            "myplugin.cmxs",
            "dllzcamlstub.so",
            "dllzcamlstub.dll",
        };
        for (to_copy) |f| {
            const src_f = try std.fs.path.join(arena, &.{ work_dir_path, f });
            if (pathExists(io, src_f)) {
                const dst_f = try std.fs.path.join(arena, &.{ bundle_dir, f });
                _ = try Dir.cwd().updateFile(io, src_f, Dir.cwd(), dst_f, .{});
            }
        }

        const rt_target_name = try std.fmt.allocPrint(arena, "ocamlrun-target{s}", .{t_ext});
        const rt_host_name = try std.fmt.allocPrint(arena, "ocamlrun{s}", .{t_ext});
        const rt_src = blk: {
            const p1 = try std.fs.path.join(arena, &.{ bin_dir, rt_target_name });
            if (pathExists(io, p1)) break :blk p1;
            break :blk try std.fs.path.join(arena, &.{ bin_dir, rt_host_name });
        };
        if (pathExists(io, rt_src)) {
            const rt_dst = try std.fs.path.join(arena, &.{ bundle_dir, rt_target_name });
            _ = try Dir.cwd().updateFile(io, rt_src, Dir.cwd(), rt_dst, .{});
        }

        if (pathExists(io, stublibs_dir)) {
            const dst_stublibs = try std.fs.path.join(arena, &.{ bundle_dir, "stublibs" });
            try Dir.cwd().createDirPath(io, dst_stublibs);
            var sdir = try Dir.openDirAbsolute(io, stublibs_dir, .{ .iterate = true });
            defer sdir.close(io);
            var it = sdir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .file) {
                    const sf = try std.fs.path.join(arena, &.{ stublibs_dir, entry.name });
                    const df = try std.fs.path.join(arena, &.{ dst_stublibs, entry.name });
                    _ = try Dir.cwd().updateFile(io, sf, Dir.cwd(), df, .{});
                }
            }
        }
        return "COMPILED (deferred bundle saved)";
    }

    return "COMPILED (target OS not runnable here)";
}

fn executeTargetBinaries(
    ctx: *Context,
    arena: Allocator,
    target: Triple,
    bin_dir: []const u8,
    stublibs_dir: []const u8,
    work_dir_path: []const u8,
    has_shared_libs: bool,
    has_natdynlink: bool,
) !void {
    const io = ctx.init.io;
    const t_ext = target.exeExt();

    var target_wrap = try buildExecWrapper(ctx, arena, target, &.{ stublibs_dir, work_dir_path });
    const caml_ld = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
        work_dir_path,
        @as(u8, if (target.isWindows()) ';' else ':'),
        stublibs_dir,
    });
    try target_wrap.env.put("CAML_LD_LIBRARY_PATH", caml_ld);
    if (target.isMacos()) {
        try target_wrap.env.put("DYLD_LIBRARY_PATH", caml_ld);
    }

    const ocamlrun_target = blk: {
        const p1 = try std.fs.path.join(arena, &.{ bin_dir, try std.fmt.allocPrint(arena, "ocamlrun-target{s}", .{t_ext}) });
        if (pathExists(io, p1)) break :blk p1;
        break :blk try std.fs.path.join(arena, &.{ bin_dir, try std.fmt.allocPrint(arena, "ocamlrun{s}", .{t_ext}) });
    };

    if (has_shared_libs) {
        const pure_byte_name = try std.fmt.allocPrint(arena, "test_pure_byte{s}", .{t_ext});
        const pure_byte_path = try std.fs.path.join(arena, &.{ work_dir_path, pure_byte_name });
        if (pathExists(io, pure_byte_path)) {
            const out = try runChecked(
                ctx,
                arena,
                try concatArgs(arena, target_wrap.prefix_argv, &.{ ocamlrun_target, pure_byte_name, "myplugin.cmo" }),
                work_dir_path,
                &target_wrap.env,
                "run pure bytecode",
            );
            if (std.mem.indexOf(u8, out, "ZCAML_VERIFY_OK") == null) return error.VerifyOutputMismatch;
        }
    }

    const custom_byte_path = try std.fs.path.join(arena, &.{ work_dir_path, try std.fmt.allocPrint(arena, "test_custom_byte{s}", .{t_ext}) });
    {
        const out = try runChecked(
            ctx,
            arena,
            try concatArgs(arena, target_wrap.prefix_argv, &.{ custom_byte_path, "myplugin.cmo" }),
            work_dir_path,
            &target_wrap.env,
            "run custom bytecode",
        );
        if (std.mem.indexOf(u8, out, "ZCAML_VERIFY_OK") == null) return error.VerifyOutputMismatch;
    }

    const nat_exe_path = try std.fs.path.join(arena, &.{ work_dir_path, try std.fmt.allocPrint(arena, "test_native_opt{s}", .{t_ext}) });
    const nat_args: []const []const u8 = if (has_natdynlink and pathExists(io, try std.fs.path.join(arena, &.{ work_dir_path, "myplugin.cmxs" })))
        &.{ nat_exe_path, "myplugin.cmxs" }
    else
        &.{nat_exe_path};
    {
        const out = try runChecked(
            ctx,
            arena,
            try concatArgs(arena, target_wrap.prefix_argv, nat_args),
            work_dir_path,
            &target_wrap.env,
            "run native executable",
        );
        if (std.mem.indexOf(u8, out, "ZCAML_VERIFY_OK") == null) return error.VerifyOutputMismatch;
    }
}

fn runDeferredBundles(
    init: std.process.Init,
    cache_dir: []const u8,
    fixtures_abs: []const u8,
    deferred_root: []const u8,
    jobs: usize,
) !void {
    _ = jobs;
    const io = init.io;
    const arena = init.arena.allocator();
    const cur = currentMachineTriple();

    var bundle_names: std.ArrayList([]const u8) = .empty;
    {
        var dir = try Dir.openDirAbsolute(io, deferred_root, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "host-")) {
                try bundle_names.append(arena, try arena.dupe(u8, entry.name));
            }
        }
    }
    std.mem.sort([]const u8, bundle_names.items, {}, strLessThan);

    var ctx: Context = .{
        .init = init,
        .cache_dir = cache_dir,
        .fixtures_abs = fixtures_abs,
        .save_deferred_abs = null,
    };

    var failures: usize = 0;
    for (bundle_names.items) |bname| {
        const sep_idx = std.mem.indexOf(u8, bname, "__target-") orelse continue;
        const h_raw = bname["host-".len..sep_idx];
        const t_raw = bname[sep_idx + "__target-".len ..];
        const host = Triple.parse(h_raw);
        const target = Triple.parse(t_raw);
        if (!canExecuteTargetOnCurrentMachine(target, cur)) continue;

        const bundle_dir = try std.fs.path.join(arena, &.{ deferred_root, bname });
        const stublibs_dir = try std.fs.path.join(arena, &.{ bundle_dir, "stublibs" });
        const t0 = Io.Clock.awake.now(io);
        const label = try std.fmt.allocPrint(arena, "{s} -> {s} (deferred)", .{
            host.shortName(arena),
            target.shortName(arena),
        });

        if (executeTargetBinaries(&ctx, arena, target, bundle_dir, stublibs_dir, bundle_dir, true, !target.isWindows())) {
            const dt = t0.untilNow(io, .awake);
            std.debug.print("  [OK]   {s:<45} ({f}) PASSED (deferred execution)\n", .{ label, dt });
        } else |err| {
            failures += 1;
            std.debug.print("  [FAIL] {s}: {t}\n", .{ label, err });
        }
    }
    if (failures > 0) std.process.exit(1);
}

fn toolCmd(
    arena: Allocator,
    prefix_argv: []const []const u8,
    bin_dir: []const u8,
    tool_name: []const u8,
    exe_ext: []const u8,
    is_bytecode_script: bool,
    is_windows_host: bool,
    extra_args: []const []const u8,
) ![]const []const u8 {
    const tool_file = try std.fmt.allocPrint(arena, "{s}{s}", .{ tool_name, exe_ext });
    const tool_path = try std.fs.path.join(arena, &.{ bin_dir, tool_file });
    if (is_bytecode_script and !is_windows_host) {
        const ocamlrun_file = try std.fmt.allocPrint(arena, "ocamlrun{s}", .{exe_ext});
        const ocamlrun_path = try std.fs.path.join(arena, &.{ bin_dir, ocamlrun_file });
        return concatArgs3(arena, prefix_argv, &.{ ocamlrun_path, tool_path }, extra_args);
    }
    return concatArgs3(arena, prefix_argv, &.{tool_path}, extra_args);
}

fn concatArgs(arena: Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn concatArgs3(arena: Allocator, a: []const []const u8, b: []const []const u8, c: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, a.len + b.len + c.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len .. a.len + b.len], b);
    @memcpy(out[a.len + b.len ..], c);
    return out;
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
        if (pathExists(io, sys_loader) and std.mem.eql(u8, target.arch, cur.arch)) {
            return "/";
        }

        const ready = try std.fs.path.join(arena, &.{ sysroot, ".musl-1.2.5-r13-ready" });
        const loader = try std.fmt.allocPrint(arena, "{s}/lib/ld-musl-{s}.so.1", .{ sysroot, target.arch });
        if (pathExists(io, ready) and pathExists(io, loader)) {
            return sysroot;
        }

        const info = blk: {
            for (musl_infos) |m| {
                if (std.mem.eql(u8, m.arch, target.arch)) break :blk m;
            }
            return error.UnsupportedMuslArch;
        };

        std.debug.print("==> Downloading Alpine musl loader for {s}...\n", .{target.raw});
        const usr_lib = try std.fs.path.join(arena, &.{ sysroot, "usr", "lib" });
        try Dir.cwd().createDirPath(io, usr_lib);

        const apk_path = try std.fs.path.join(arena, &.{ sysroot, "musl-1.2.5-r13.apk" });
        const url = try std.fmt.allocPrint(arena, "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/{s}/musl-1.2.5-r13.apk", .{info.apk_arch});
        const dl = try std.process.run(gpa, io, .{ .argv = &.{ "curl", "-fsSL", url, "-o", apk_path } });
        gpa.free(dl.stdout);
        gpa.free(dl.stderr);
        if (!dl.term.success()) return error.DownloadFailed;

        // Extract lib/ld-musl-<arch>.so.1
        const member = try std.fmt.allocPrint(arena, "lib/ld-musl-{s}.so.1", .{target.arch});
        const ex = try std.process.run(gpa, io, .{
            .argv = &.{ "tar", "--ignore-zeros", "--warning=no-unknown-keyword", "-xOzf", apk_path, member },
        });
        defer gpa.free(ex.stdout);
        defer gpa.free(ex.stderr);
        if (!ex.term.success()) return error.ExtractFailed;

        const out_loader = try std.fmt.allocPrint(arena, "{s}/ld-musl-{s}.so.1", .{ usr_lib, target.arch });
        try Dir.cwd().writeFile(io, .{
            .sub_path = out_loader,
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

    // Foreign glibc target on Linux: check Ubuntu cross-libc in /usr/<arch>-linux-gnu first
    const multiarch = try std.fmt.allocPrint(arena, "/usr/{s}-linux-gnu", .{target.arch});
    const multiarch_libc = try std.fmt.allocPrint(arena, "{s}/lib/libc.so.6", .{multiarch});
    if (pathExists(io, multiarch_libc)) {
        return multiarch;
    }

    const ready = try std.fs.path.join(arena, &.{ sysroot, ".ready-v2" });
    if (pathExists(io, ready)) {
        return sysroot;
    }

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
