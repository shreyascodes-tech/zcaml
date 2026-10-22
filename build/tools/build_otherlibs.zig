const std = @import("std");
const utils = @import("utils.zig");
const build_stdlib = @import("build_stdlib.zig");
const InputFile = utils.InputFile;
const InputDir = utils.InputDir;
const OutputDir = utils.OutputDir;

const Self = @This();

ocamlrun: InputFile,
compiler_dir: InputDir,
stdlib_dir: InputDir,
ocaml_src_dir: InputDir,
unix_or_win32: []const u8,
is_windows_target: bool = false,
has_byt_suffix: bool = false,
has_modern_dynlink: bool = false,
dynlink_config_ml: ?InputFile = null,
dynlink_meta: InputFile,
unix_meta: InputFile,
str_meta: InputFile,
threads_meta: InputFile,
runtime_events_meta: InputFile,
otherlibs_compflags: []const []const u8 = &.{},
systhreads_compflags: []const []const u8 = &.{},
dynlink_pack_intfs: []const []const u8 = &.{},
dynlink_pack_sources: []const []const u8 = &.{},
out_dir: OutputDir,

pub fn run(self: *Self, init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_dir_handle = try self.out_dir.open(io, .{});
    defer out_dir_handle.close(io);

    const out_dir_path = self.out_dir.path();
    const src_root_path = self.ocaml_src_dir.path();
    const compiler_dir_path = self.compiler_dir.path();
    const ocamlc_byte_path = try std.fmt.allocPrint(arena, "{s}/bin/ocamlc.byte", .{compiler_dir_path});

    const lib_subdirs = [_][]const u8{
        "dynlink",
        "dynlink/byte",
        "unix",
        "str",
        "threads",
        "runtime_events",
    };
    for (lib_subdirs) |sub| {
        try out_dir_handle.createDirPath(io, sub);
    }

    // Write META files
    try writeInputFileToSubpath(io, gpa, self.dynlink_meta, out_dir_handle, "dynlink/META");
    try writeInputFileToSubpath(io, gpa, self.unix_meta, out_dir_handle, "unix/META");
    try writeInputFileToSubpath(io, gpa, self.str_meta, out_dir_handle, "str/META");
    try writeInputFileToSubpath(io, gpa, self.threads_meta, out_dir_handle, "threads/META");
    try writeInputFileToSubpath(io, gpa, self.runtime_events_meta, out_dir_handle, "runtime_events/META");

    // 1. Build str, runtime_events, and unix
    try self.buildStr(io, gpa, arena, src_root_path, out_dir_handle, out_dir_path, ocamlc_byte_path);
    try self.buildRuntimeEvents(io, gpa, arena, src_root_path, out_dir_handle, out_dir_path, ocamlc_byte_path);
    try self.buildUnix(io, gpa, arena, src_root_path, out_dir_handle, out_dir_path, ocamlc_byte_path);

    // 2. Build systhreads (depends on unix.cmi)
    try self.buildSysthreads(io, gpa, arena, src_root_path, out_dir_handle, out_dir_path, ocamlc_byte_path);

    // 3. Build dynlink
    try self.buildDynlink(io, gpa, arena, src_root_path, compiler_dir_path, out_dir_handle, out_dir_path, ocamlc_byte_path);
}

fn buildStr(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    ocamlc_byte_path: []const u8,
) !void {
    try copyFileRel(io, gpa, src_root_path, "otherlibs/str/str.mli", out_dir_handle, "str/str.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/str/str.ml", out_dir_handle, "str/str.ml");

    const str_dir = try std.fmt.allocPrint(arena, "{s}/str", .{out_dir_path});
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, str_dir, &.{}, "str/str.mli", "str/str.cmi", out_dir_path);
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, str_dir, &.{}, "str/str.ml", "str/str.cmo", out_dir_path);

    const clib = if (self.has_byt_suffix) "-lcamlstrbyt" else "-lcamlstr";
    try self.linkOtherlibCma(
        io,
        gpa,
        arena,
        ocamlc_byte_path,
        str_dir,
        &.{ "-dllib", clib, "-cclib", clib },
        "str/str.cma",
        &.{"str/str.cmo"},
        out_dir_path,
    );
}

fn buildRuntimeEvents(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    ocamlc_byte_path: []const u8,
) !void {
    try copyFileRel(io, gpa, src_root_path, "otherlibs/runtime_events/runtime_events.mli", out_dir_handle, "runtime_events/runtime_events.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/runtime_events/runtime_events.ml", out_dir_handle, "runtime_events/runtime_events.ml");

    const re_dir = try std.fmt.allocPrint(arena, "{s}/runtime_events", .{out_dir_path});
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, re_dir, &.{}, "runtime_events/runtime_events.mli", "runtime_events/runtime_events.cmi", out_dir_path);
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, re_dir, &.{}, "runtime_events/runtime_events.ml", "runtime_events/runtime_events.cmo", out_dir_path);

    const clib = if (self.has_byt_suffix) "-lcamlruntime_eventsbyt" else "-lcamlruntime_events";
    try self.linkOtherlibCma(
        io,
        gpa,
        arena,
        ocamlc_byte_path,
        re_dir,
        &.{ "-dllib", clib, "-cclib", clib },
        "runtime_events/runtime_events.cma",
        &.{"runtime_events/runtime_events.cmo"},
        out_dir_path,
    );
}

fn buildUnix(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    ocamlc_byte_path: []const u8,
) !void {
    const unix_ml_src = try std.fmt.allocPrint(arena, "otherlibs/unix/unix_{s}.ml", .{self.unix_or_win32});
    try copyFileRel(io, gpa, src_root_path, unix_ml_src, out_dir_handle, "unix/unix.ml");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/unix/unix.mli", out_dir_handle, "unix/unix.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/unix/unixLabels.ml", out_dir_handle, "unix/unixLabels.ml");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/unix/unixLabels.mli", out_dir_handle, "unix/unixLabels.mli");

    // Expand module aliases in unixLabels.mli in-place during compilation, then restore
    const raw_labels_mli = try out_dir_handle.readFileAlloc(io, "unix/unixLabels.mli", gpa, .unlimited);
    defer gpa.free(raw_labels_mli);
    const expanded_labels_mli = try build_stdlib.expandModuleAliases(arena, "unixLabels.mli", raw_labels_mli);
    try out_dir_handle.writeFile(io, .{ .sub_path = "unix/unixLabels.mli", .data = expanded_labels_mli });

    const unix_dir = try std.fmt.allocPrint(arena, "{s}/unix", .{out_dir_path});
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, unix_dir, &.{"-nolabels"}, "unix/unix.mli", "unix/unix.cmi", out_dir_path);
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, unix_dir, &.{"-nolabels"}, "unix/unix.ml", "unix/unix.cmo", out_dir_path);
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, unix_dir, &.{"-nolabels"}, "unix/unixLabels.mli", "unix/unixLabels.cmi", out_dir_path);
    try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, unix_dir, &.{"-nolabels"}, "unix/unixLabels.ml", "unix/unixLabels.cmo", out_dir_path);

    // Restore unexpanded unixLabels.mli
    try out_dir_handle.writeFile(io, .{ .sub_path = "unix/unixLabels.mli", .data = raw_labels_mli });

    const clib = if (self.has_byt_suffix) "-lunixbyt" else "-lunix";
    var link_flags: std.ArrayList([]const u8) = .empty;
    try link_flags.appendSlice(arena, &.{ "-dllib", clib, "-cclib", clib });
    if (self.is_windows_target) {
        try link_flags.appendSlice(arena, &.{ "-cclib", "-lws2_32", "-cclib", "-ladvapi32" });
    }

    try self.linkOtherlibCma(
        io,
        gpa,
        arena,
        ocamlc_byte_path,
        unix_dir,
        link_flags.items,
        "unix/unix.cma",
        &.{ "unix/unix.cmo", "unix/unixLabels.cmo" },
        out_dir_path,
    );
}

fn buildSysthreads(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    ocamlc_byte_path: []const u8,
) !void {
    try copyFileRel(io, gpa, src_root_path, "otherlibs/systhreads/thread.mli", out_dir_handle, "threads/thread.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/systhreads/thread.ml", out_dir_handle, "threads/thread.ml");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/systhreads/event.mli", out_dir_handle, "threads/event.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/systhreads/event.ml", out_dir_handle, "threads/event.ml");

    const threads_dir = try std.fmt.allocPrint(arena, "{s}/threads", .{out_dir_path});
    const unix_dir = try std.fmt.allocPrint(arena, "{s}/unix", .{out_dir_path});
    var threads_flags: std.ArrayList([]const u8) = .empty;
    try threads_flags.appendSlice(arena, self.systhreads_compflags);
    try threads_flags.appendSlice(arena, &.{ "-I", unix_dir });

    try self.compileOtherlibUnitWithFlags(io, gpa, arena, ocamlc_byte_path, threads_dir, threads_flags.items, "threads/thread.mli", "threads/thread.cmi", out_dir_path);
    try self.compileOtherlibUnitWithFlags(io, gpa, arena, ocamlc_byte_path, threads_dir, threads_flags.items, "threads/event.mli", "threads/event.cmi", out_dir_path);
    try self.compileOtherlibUnitWithFlags(io, gpa, arena, ocamlc_byte_path, threads_dir, threads_flags.items, "threads/thread.ml", "threads/thread.cmo", out_dir_path);
    try self.compileOtherlibUnitWithFlags(io, gpa, arena, ocamlc_byte_path, threads_dir, threads_flags.items, "threads/event.ml", "threads/event.cmo", out_dir_path);

    try self.linkOtherlibCma(
        io,
        gpa,
        arena,
        ocamlc_byte_path,
        threads_dir,
        &.{ "-I", unix_dir, "-dllib", "-lthreads", "-cclib", "-lthreads" },
        "threads/threads.cma",
        &.{ "threads/thread.cmo", "threads/event.cmo" },
        out_dir_path,
    );
}

fn buildDynlink(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_root_path: []const u8,
    compiler_dir_path: []const u8,
    out_dir_handle: std.Io.Dir,
    out_dir_path: []const u8,
    ocamlc_byte_path: []const u8,
) !void {
    const dynlink_dir = try std.fmt.allocPrint(arena, "{s}/dynlink", .{out_dir_path});
    const dynlink_byte_dir = try std.fmt.allocPrint(arena, "{s}/dynlink/byte", .{out_dir_path});

    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_types.mli", out_dir_handle, "dynlink/dynlink_types.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_types.ml", out_dir_handle, "dynlink/dynlink_types.ml");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_platform_intf.ml", out_dir_handle, "dynlink/dynlink_platform_intf.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_platform_intf.ml", out_dir_handle, "dynlink/dynlink_platform_intf.ml");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_common.mli", out_dir_handle, "dynlink/dynlink_common.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_common.ml", out_dir_handle, "dynlink/dynlink_common.ml");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink.mli", out_dir_handle, "dynlink/dynlink.mli");
    try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/byte/dynlink.ml", out_dir_handle, "dynlink/byte/dynlink.ml");

    if (self.has_modern_dynlink) {
        // OCaml 5.3+: dynlink_config.ml, dynlink_cmo_format.mli, dynlink_cmxs_format.mli, byte/dynlink_symtable.{mli,ml}
        try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/dynlink_config.mli", out_dir_handle, "dynlink/dynlink_config.mli");
        try writeInputFileToSubpath(io, gpa, self.dynlink_config_ml.?, out_dir_handle, "dynlink/dynlink_config.ml");
        try copyFileRel(io, gpa, src_root_path, "file_formats/cmo_format.mli", out_dir_handle, "dynlink/dynlink_cmo_format.mli");
        try copyFileRel(io, gpa, src_root_path, "file_formats/cmxs_format.mli", out_dir_handle, "dynlink/dynlink_cmxs_format.mli");
        try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/byte/dynlink_symtable.mli", out_dir_handle, "dynlink/byte/dynlink_symtable.mli");
        try copyFileRel(io, gpa, src_root_path, "otherlibs/dynlink/byte/dynlink_symtable.ml", out_dir_handle, "dynlink/byte/dynlink_symtable.ml");

        const extra_inc = [_][]const u8{ "-I", dynlink_byte_dir, "-w", "-40" };
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_cmo_format.mli", "dynlink/dynlink_cmo_format.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_cmxs_format.mli", "dynlink/dynlink_cmxs_format.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_config.mli", "dynlink/dynlink_config.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_config.ml", "dynlink/dynlink_config.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_types.mli", "dynlink/dynlink_types.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_types.ml", "dynlink/dynlink_types.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_platform_intf.mli", "dynlink/dynlink_platform_intf.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_platform_intf.ml", "dynlink/dynlink_platform_intf.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_common.mli", "dynlink/dynlink_common.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_common.ml", "dynlink/dynlink_common.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/byte/dynlink_symtable.mli", "dynlink/byte/dynlink_symtable.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/byte/dynlink_symtable.ml", "dynlink/byte/dynlink_symtable.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink.mli", "dynlink/dynlink.cmi", out_dir_path);

        // Copy dynlink.cmi and dynlink.mli into dynlink/byte/
        try copyFileRel(io, gpa, out_dir_path, "dynlink/dynlink.cmi", out_dir_handle, "dynlink/byte/dynlink.cmi");
        try copyFileRel(io, gpa, out_dir_path, "dynlink/dynlink.mli", out_dir_handle, "dynlink/byte/dynlink.mli");

        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/byte/dynlink.ml", "dynlink/byte/dynlink.cmo", out_dir_path);

        try self.linkOtherlibCma(
            io,
            gpa,
            arena,
            ocamlc_byte_path,
            dynlink_dir,
            &.{ "-I", dynlink_byte_dir },
            "dynlink/dynlink.cma",
            &.{
                "dynlink/dynlink_config.cmo",
                "dynlink/dynlink_types.cmo",
                "dynlink/dynlink_platform_intf.cmo",
                "dynlink/dynlink_common.cmo",
                "dynlink/byte/dynlink_symtable.cmo",
                "dynlink/byte/dynlink.cmo",
            },
            out_dir_path,
        );
    } else {
        // OCaml 5.0 - 5.2: pack Dynlink_compilerlibs into dynlink/byte/dynlink_compilerlibs.cmo
        try out_dir_handle.createDirPath(io, "dynlink/dynlink_compilerlibs");
        const local_src_dir = try std.fmt.allocPrint(arena, "{s}/dynlink/dynlink_compilerlibs", .{out_dir_path});
        const pack_flags = [_][]const u8{
            "-for-pack",
            "Dynlink_compilerlibs",
            "-I",
            local_src_dir,
            "-w",
            "-40-66-70",
        };

        // Parse root .depend to get bare basename .cmi -> []bare .cmi dependencies
        const root_dep_path = try std.fmt.allocPrint(arena, "{s}/.depend", .{src_root_path});
        const root_dep_src = try std.Io.Dir.cwd().readFileAlloc(io, root_dep_path, gpa, .unlimited);
        defer gpa.free(root_dep_src);
        const cmi_dep_map = try parseBareCmiDependMap(arena, root_dep_src);

        // Copy all COMPILERLIBS_SOURCES (.ml + .mli) and COMPILERLIBS_INTFS (.mli as both .mli and .ml)
        // in exact COMPILERLIBS_COPIED_SOURCES order: sources first, then intfs
        var stems: std.ArrayList([]const u8) = .empty;
        var stem_set: std.StringHashMapUnmanaged(void) = .empty;

        for (self.dynlink_pack_sources) |ml_rel| {
            const mli_rel = try std.fmt.allocPrint(arena, "{s}i", .{ml_rel});
            const base = std.fs.path.basename(ml_rel);
            const stem = base[0 .. base.len - 3]; // strip .ml
            const dest_mli = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.mli", .{stem});
            const dest_ml = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.ml", .{stem});

            try copyFileRel(io, gpa, compiler_dir_path, mli_rel, out_dir_handle, dest_mli);
            try copyFileRel(io, gpa, compiler_dir_path, ml_rel, out_dir_handle, dest_ml);
            try stems.append(arena, stem);
            try stem_set.put(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{stem}), {});
        }

        for (self.dynlink_pack_intfs) |intf_rel| {
            const base = std.fs.path.basename(intf_rel);
            const stem = base[0 .. base.len - 4]; // strip .mli
            const dest_mli = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.mli", .{stem});
            const dest_ml = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.ml", .{stem});

            try copyFileRel(io, gpa, compiler_dir_path, intf_rel, out_dir_handle, dest_mli);
            try copyFileRel(io, gpa, compiler_dir_path, intf_rel, out_dir_handle, dest_ml);
            try stems.append(arena, stem);
            try stem_set.put(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{stem}), {});
        }

        // Compile all .cmi files in topological wave order
        const total = stems.items.len;
        var done = try arena.alloc(bool, total);
        @memset(done, false);
        var built_cmis: std.StringHashMapUnmanaged(void) = .empty;
        var completed: usize = 0;

        while (completed < total) {
            var wave_indices: std.ArrayList(usize) = .empty;
            for (stems.items, 0..) |stem, idx| {
                if (done[idx]) continue;
                const cmi_name = try std.fmt.allocPrint(arena, "{s}.cmi", .{stem});
                var ready = true;
                if (cmi_dep_map.get(cmi_name)) |deps| {
                    for (deps) |dep_cmi| {
                        if (std.mem.eql(u8, dep_cmi, cmi_name)) continue;
                        if (stem_set.contains(dep_cmi) and !built_cmis.contains(dep_cmi)) {
                            ready = false;
                            break;
                        }
                    }
                }
                if (ready) {
                    try wave_indices.append(arena, idx);
                }
            }

            if (wave_indices.items.len == 0) {
                @panic("dynlink_compilerlibs .depend safety check failed: cycle in .cmi dependencies");
            }

            for (wave_indices.items) |idx| {
                const stem = stems.items[idx];
                const dest_mli = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.mli", .{stem});
                const dest_cmi = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.cmi", .{stem});
                try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &pack_flags, dest_mli, dest_cmi, out_dir_path);
                done[idx] = true;
                try built_cmis.put(arena, try std.fmt.allocPrint(arena, "{s}.cmi", .{stem}), {});
                completed += 1;
            }
        }

        // Compile all .cmo files in order (all .cmi files are now ready)
        var pack_cmos: std.ArrayList([]const u8) = .empty;
        for (stems.items) |stem| {
            const dest_ml = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.ml", .{stem});
            const dest_cmo = try std.fmt.allocPrint(arena, "dynlink/dynlink_compilerlibs/{s}.cmo", .{stem});
            try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &pack_flags, dest_ml, dest_cmo, out_dir_path);
            try pack_cmos.append(arena, dest_cmo);
        }

        // Pack into dynlink/byte/dynlink_compilerlibs.cmo
        {
            var pack_argv: std.ArrayList([]const u8) = .empty;
            try pack_argv.appendSlice(arena, &.{
                self.ocamlrun.path(),
                ocamlc_byte_path,
                "-nostdlib",
                "-I",
                self.stdlib_dir.path(),
                "-g",
                "-pack",
                "-o",
                try std.fmt.allocPrint(arena, "{s}/dynlink/byte/dynlink_compilerlibs.cmo", .{out_dir_path}),
            });
            for (pack_cmos.items) |cmo_rel| {
                try pack_argv.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, cmo_rel }));
            }
            try runChecked(io, gpa, pack_argv.items);
        }

        const extra_inc = [_][]const u8{ "-I", dynlink_byte_dir, "-w", "-40-66-70" };
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_types.mli", "dynlink/dynlink_types.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_types.ml", "dynlink/dynlink_types.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_platform_intf.mli", "dynlink/dynlink_platform_intf.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_platform_intf.ml", "dynlink/dynlink_platform_intf.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_common.mli", "dynlink/dynlink_common.cmi", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink_common.ml", "dynlink/dynlink_common.cmo", out_dir_path);
        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/dynlink.mli", "dynlink/dynlink.cmi", out_dir_path);

        try copyFileRel(io, gpa, out_dir_path, "dynlink/dynlink.cmi", out_dir_handle, "dynlink/byte/dynlink.cmi");
        try copyFileRel(io, gpa, out_dir_path, "dynlink/dynlink.mli", out_dir_handle, "dynlink/byte/dynlink.mli");

        try self.compileOtherlibUnit(io, gpa, arena, ocamlc_byte_path, dynlink_dir, &extra_inc, "dynlink/byte/dynlink.ml", "dynlink/byte/dynlink.cmo", out_dir_path);

        try self.linkOtherlibCma(
            io,
            gpa,
            arena,
            ocamlc_byte_path,
            dynlink_dir,
            &.{ "-I", dynlink_byte_dir },
            "dynlink/dynlink.cma",
            &.{
                "dynlink/byte/dynlink_compilerlibs.cmo",
                "dynlink/dynlink_types.cmo",
                "dynlink/dynlink_platform_intf.cmo",
                "dynlink/dynlink_common.cmo",
                "dynlink/byte/dynlink.cmo",
            },
            out_dir_path,
        );
    }
}

fn compileOtherlibUnit(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ocamlc_byte_path: []const u8,
    lib_dir_full: []const u8,
    extra_flags: []const []const u8,
    src_rel: []const u8,
    out_rel: []const u8,
    out_dir_path: []const u8,
) !void {
    var combined_flags: std.ArrayList([]const u8) = .empty;
    try combined_flags.appendSlice(arena, self.otherlibs_compflags);
    try combined_flags.appendSlice(arena, extra_flags);
    return self.compileOtherlibUnitWithFlags(io, gpa, arena, ocamlc_byte_path, lib_dir_full, combined_flags.items, src_rel, out_rel, out_dir_path);
}

fn compileOtherlibUnitWithFlags(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ocamlc_byte_path: []const u8,
    lib_dir_full: []const u8,
    flags: []const []const u8,
    src_rel: []const u8,
    out_rel: []const u8,
    out_dir_path: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        self.ocamlrun.path(),
        ocamlc_byte_path,
        "-nostdlib",
        "-I",
        self.stdlib_dir.path(),
        "-I",
        lib_dir_full,
    });
    try argv.appendSlice(arena, flags);
    try argv.appendSlice(arena, &.{
        "-o",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, out_rel }),
        "-c",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, src_rel }),
    });
    try runChecked(io, gpa, argv.items);
}

fn linkOtherlibCma(
    self: *Self,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ocamlc_byte_path: []const u8,
    lib_dir_full: []const u8,
    extra_flags: []const []const u8,
    cma_rel: []const u8,
    cmos: []const []const u8,
    out_dir_path: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        self.ocamlrun.path(),
        ocamlc_byte_path,
        "-nostdlib",
        "-I",
        self.stdlib_dir.path(),
        "-I",
        lib_dir_full,
        "-g",
        "-a",
        "-linkall",
    });
    try argv.appendSlice(arena, extra_flags);
    try argv.appendSlice(arena, &.{
        "-o",
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, cma_rel }),
    });
    for (cmos) |cmo_rel| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_dir_path, cmo_rel }));
    }
    try runChecked(io, gpa, argv.items);
}

fn writeInputFileToSubpath(
    io: std.Io,
    gpa: std.mem.Allocator,
    input: InputFile,
    out_dir_handle: std.Io.Dir,
    sub_path: []const u8,
) !void {
    const bytes = try input.readAll(io, gpa);
    defer gpa.free(bytes);
    try out_dir_handle.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
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

fn parseBareCmiDependMap(
    arena: std.mem.Allocator,
    depend_src: []const u8,
) !std.StringHashMapUnmanaged([]const []const u8) {
    var map: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var joined_line: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, depend_src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "ifeq ") or std.mem.startsWith(u8, trimmed, "endif")) continue;

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
            if (std.mem.endsWith(u8, dep_tok, ".cmi")) {
                try deps.append(arena, std.fs.path.basename(dep_tok));
            }
        }

        var lhs_it = std.mem.tokenizeAny(u8, lhs, " \t");
        while (lhs_it.next()) |target_tok| {
            if (std.mem.startsWith(u8, target_tok, "lex/")) continue;
            if (std.mem.endsWith(u8, target_tok, ".cmi")) {
                try map.put(arena, std.fs.path.basename(target_tok), deps.items);
            }
        }
    }

    return map;
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
