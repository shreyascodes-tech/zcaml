//! `ocaml-gen configure`: renders every file OCaml's `./configure` generates.

const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;

const Target = @import("Target");
const Version = @import("Version.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const template = @import("template.zig");
const fail = cli.fail;

const Args = struct {
    src: []const u8,
    out: []const u8,
    target: []const u8,
    host: ?[]const u8 = null,
    cc: []const u8,
    ar: []const u8,
    asm_: ?[]const u8 = null,
    packld: ?[]const u8 = null,
    cc_vendor: ?[]const u8 = null,
    bindir: ?[]const u8 = null,
    libdir: ?[]const u8 = null,
    relative_libdir: ?[]const u8 = null,
    zstd_libs: ?[]const u8 = null,
    codegen_invariants: bool = false,
};

const headers = .{
    .{ "runtime/caml/m.h", config.MH },
    .{ "runtime/caml/s.h", config.SH },
    .{ "runtime/caml/version.h", config.VersionH },
    .{ "runtime/caml/exec.h", config.ExecH },
};

const at_templates = [_][]const u8{
    "stdlib/sys.ml",
    "otherlibs/dynlink/dynlink_config.ml",
};

/// Concatenated into `utils/config.ml`, which is what the compiler compiles.
const config_ml_parts = [_][]const u8{
    "utils/config.generated.ml",
    "utils/config.common.ml",
};

pub fn run(io: Io, gpa: std.mem.Allocator, argv: *std.process.Args.Iterator) !void {
    const args = try cli.parseArgs(Args, gpa, argv);

    const target = try resolveTarget(io, args.target);
    const host = if (args.host) |h| try resolveTarget(io, h) else target;

    const src = Io.Dir.cwd().openDir(io, args.src, .{}) catch |err|
        return fail("{s}: {t}", .{ args.src, err });
    defer src.close(io);

    const version_m4 = try readSrc(io, gpa, src, "build-aux/ocaml_version.m4");
    defer gpa.free(version_m4);
    const version = Version.parse(version_m4) catch |err|
        return fail("build-aux/ocaml_version.m4: {t}", .{err});

    const layout: config.Layout = if (args.relative_libdir) |rel| blk: {
        if (args.libdir != null) return fail("--libdir and --relative-libdir are mutually exclusive", .{});
        break :blk .{ .relative = .{ .bindir_to_libdir = rel } };
    } else .{ .absolute = .{
        .bindir = args.bindir orelse return fail("--bindir is required without --relative-libdir", .{}),
        .libdir = args.libdir orelse return fail("--libdir is required without --relative-libdir", .{}),
    } };

    const opts: config.Options = .{
        .version = version,
        .host = &host,
        .target = &target,
        .tools = .{
            .cc = args.cc,
            .ar = args.ar,
            .asm_ = args.asm_,
            .packld = args.packld,
            .cc_vendor = args.cc_vendor orelse config.Tools.default_cc_vendor,
        },
        .layout = layout,
        .features = .{ .zstd_libs = args.zstd_libs },
        .codegen_invariants = args.codegen_invariants,
    };

    const out = try cli.Out.open(io, args.out);
    defer out.close();

    inline for (headers) |entry| {
        const path, const T = entry;
        var file = try out.create(path);
        defer file.close();
        const used = try renderTemplate(io, gpa, src, file.writer(), path, T.init(opts), .undef);
        try file.finish();
        var unused = used.complement().iterator();
        if (unused.next()) |f| return fail("{s}.in: value '{s}' has no slot in the template", .{ path, @tagName(f) });
    }

    const substs = config.Substs.init(opts) catch |err| return fail("substitutions: {t}", .{err});
    var used: template.Used(config.Substs) = .initEmpty();
    for (at_templates) |path| {
        var file = try out.create(path);
        defer file.close();
        used.setUnion(try renderTemplate(io, gpa, src, file.writer(), path, substs, .at));
        try file.finish();
    }
    {
        var file = try out.create("utils/config.ml");
        defer file.close();
        for (config_ml_parts) |path| {
            used.setUnion(try renderTemplate(io, gpa, src, file.writer(), path, substs, .at));
        }
        try file.finish();
    }
    // QS is only referenced by templates that embed a quoted string.
    used.insert(.QS);
    var unused = used.complement().iterator();
    if (unused.next()) |f| return fail("substitution '{s}' is not used by any template", .{@tagName(f)});

    try out.write("runtime/build_config.h", config.BuildConfigH.init(opts));
    try out.write("runtime/ld.conf", config.LdConf.init(opts));
}

/// `<src>/<path>.in` → `w`; returns the fields the template referenced.
fn renderTemplate(
    io: Io,
    gpa: std.mem.Allocator,
    src: Io.Dir,
    w: *Writer,
    path: []const u8,
    values: anytype,
    comptime style: template.Style,
) !template.Used(@TypeOf(values)) {
    const T = @TypeOf(values);
    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const in_path = std.fmt.bufPrint(&in_buf, "{s}.in", .{path}) catch
        return fail("path too long: {s}.in", .{path});

    const text = try readSrc(io, gpa, src, in_path);
    defer gpa.free(text);

    var diag: template.Diagnostic = .{};
    const used = template.check(T, style, text, &diag) catch |err| switch (err) {
        error.UnknownVariable => return fail("{s}: no value for '{s}'", .{ in_path, diag.name }),
    };
    try w.print("{f}", .{template.Rendered(T, style){
        .text = text,
        .values = values,
        .input_name = std.fs.path.basename(in_path),
    }});
    return used;
}

fn readSrc(io: Io, gpa: std.mem.Allocator, src: Io.Dir, path: []const u8) ![]u8 {
    return src.readFileAlloc(io, path, gpa, .unlimited) catch |err|
        return fail("{s}: {t}", .{ path, err });
}

fn resolveTarget(io: Io, triple: []const u8) !Target {
    const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err|
        return fail("invalid target '{s}': {t}", .{ triple, err });
    const resolved = std.zig.system.resolveTargetQuery(io, query) catch |err|
        return fail("cannot resolve target '{s}': {t}", .{ triple, err });
    return Target.resolve(resolved) catch |err|
        return fail("unsupported target '{s}': {t}", .{ triple, err });
}
