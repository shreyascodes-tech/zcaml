//! `ocaml-gen configure`: renders every file OCaml's `./configure` generates.

const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;

const configure = @import("../configure.zig");
const Target = @import("../Target.zig");
const Version = @import("../Version.zig");
const gen = @import("../gen.zig");
const fail = gen.fail;

const Args = struct {
    src: []const u8 = undefined,
    out: []const u8 = undefined,
    target: []const u8 = undefined,
    host: ?[]const u8 = null,
    cc: []const u8 = undefined,
    ar: []const u8 = undefined,
    asm_: ?[]const u8 = null,
    packld: ?[]const u8 = null,
    cc_vendor: ?[]const u8 = null,
    bindir: ?[]const u8 = null,
    libdir: ?[]const u8 = null,
    relative_libdir: ?[]const u8 = null,
    zstd_libs: ?[]const u8 = null,
    codegen_invariants: bool = false,
};

/// Rendered with `renderUndef`: one struct field per `#undef` in the template.
const headers = .{
    .{ "runtime/caml/m.h", configure.MH },
    .{ "runtime/caml/s.h", configure.SH },
    .{ "runtime/caml/version.h", configure.VersionH },
    .{ "runtime/caml/exec.h", configure.ExecH },
};

/// Rendered with `renderAt`, sharing one `Substs`. `utils/config.generated.ml`
/// and `utils/config.common.ml` are concatenated into `utils/config.ml`, which
/// is what the compiler actually compiles.
const at_templates = [_][]const u8{
    "utils/config.generated.ml",
    "utils/config.common.ml",
    "stdlib/sys.ml",
    "otherlibs/dynlink/dynlink_config.ml",
};

pub fn run(io: Io, gpa: std.mem.Allocator, argv: *std.process.Args.Iterator) !void {
    const args = try gen.parseArgs(Args, argv);

    const target = try resolveTarget(io, args.target);
    const host = if (args.host) |h| try resolveTarget(io, h) else target;

    const version_m4 = try gen.readSrc(io, gpa, args.src, "build-aux", "ocaml_version.m4");
    defer gpa.free(version_m4);
    const version = Version.parse(version_m4) catch |err|
        return fail("build-aux/ocaml_version.m4: {t}", .{err});

    const layout: configure.Layout = if (args.relative_libdir) |rel| blk: {
        if (args.libdir != null) return fail("--libdir and --relative-libdir are mutually exclusive", .{});
        break :blk .{ .relative = .{ .bindir_to_libdir = rel } };
    } else .{ .absolute = .{
        .bindir = args.bindir orelse return fail("--bindir is required without --relative-libdir", .{}),
        .libdir = args.libdir orelse return fail("--libdir is required without --relative-libdir", .{}),
    } };

    var opts: configure.Options = .{
        .version = version,
        .host = &host,
        .target = &target,
        .tools = .{
            .cc = args.cc,
            .ar = args.ar,
            .asm_ = args.asm_,
            .packld = args.packld,
        },
        .layout = layout,
        .zstd = args.zstd_libs != null,
        .zstd_libs = args.zstd_libs orelse "",
        .codegen_invariants = args.codegen_invariants,
    };
    if (args.cc_vendor) |v| opts.tools.cc_vendor = v;

    const out = try Io.Dir.cwd().createDirPathOpen(io, args.out, .{});
    defer out.close(io);

    inline for (headers) |entry| {
        const path, const T = entry;
        _ = try renderFile(io, gpa, args.src, out, path, T.init(opts), .undef);
    }

    const substs = configure.Substs.init(opts) catch |err| return fail("substitutions: {t}", .{err});
    var used: configure.Used(configure.Substs) = .initEmpty();
    for (at_templates) |path| {
        used.setUnion(try renderFile(io, gpa, args.src, out, path, substs, .at));
    }
    // QS is only referenced by templates that embed a quoted string, so it may
    // legitimately go unused; everything else indicates a stale `Substs`.
    used.insert(.QS);
    var unused = used.complement().iterator();
    if (unused.next()) |f| return fail("substitution '{s}' is not used by any template", .{@tagName(f)});

    try concat(io, gpa, out, "utils/config.ml", &.{
        "utils/config.generated.ml",
        "utils/config.common.ml",
    });

    try gen.writeFile(io, out, "runtime/build_config.h", print, .{configure.BuildConfigH.init(opts)});
    try gen.writeFile(io, out, "runtime/ld.conf", print, .{configure.LdConf.init(opts)});
}

const Style = enum { undef, at };

/// Renders `<src>/<path>.in` to `<out>/<path>`, returning which fields of
/// `values` the template used (always empty for `.undef`, which requires that
/// every field is used).
fn renderFile(
    io: Io,
    gpa: std.mem.Allocator,
    src: []const u8,
    out: Io.Dir,
    path: []const u8,
    values: anytype,
    comptime style: Style,
) !configure.Used(@TypeOf(values)) {
    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const in_path = std.fmt.bufPrint(&in_buf, "{s}.in", .{std.fs.path.basename(path)}) catch
        return fail("path too long: {s}.in", .{path});

    const template = try gen.readSrc(io, gpa, src, std.fs.path.dirname(path) orelse ".", in_path);
    defer gpa.free(template);

    var file = try gen.create(io, out, path);
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);

    var diag: configure.Diagnostic = .{};
    const result = render(&fw.interface, template, values, in_path, &diag, style) catch |err| switch (err) {
        error.UnknownVariable => return fail("{s}.in: no value for '{s}'", .{ path, diag.name }),
        error.UnusedVariable => return fail("{s}.in: value '{s}' has no slot in the template", .{ path, diag.name }),
        else => |e| return e,
    };
    try fw.interface.flush();
    return result;
}

fn render(
    w: *Writer,
    template: []const u8,
    values: anytype,
    name: []const u8,
    diag: *configure.Diagnostic,
    comptime style: Style,
) configure.RenderError!configure.Used(@TypeOf(values)) {
    switch (style) {
        .undef => {
            try configure.renderUndef(w, template, values, name, diag);
            return .initEmpty();
        },
        .at => return configure.renderAt(w, template, values, name, diag),
    }
}

fn concat(io: Io, gpa: std.mem.Allocator, out: Io.Dir, path: []const u8, parts: []const []const u8) !void {
    var file = try gen.create(io, out, path);
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    for (parts) |part| {
        const data = try out.readFileAlloc(io, part, gpa, .unlimited);
        defer gpa.free(data);
        try fw.interface.writeAll(data);
    }
    try fw.interface.flush();
}

fn print(w: *Writer, value: anytype) Writer.Error!void {
    try w.print("{f}", .{value});
}

fn resolveTarget(io: Io, triple: []const u8) !Target {
    const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err|
        return fail("invalid target '{s}': {t}", .{ triple, err });
    const resolved = std.zig.system.resolveTargetQuery(io, query) catch |err|
        return fail("cannot resolve target '{s}': {t}", .{ triple, err });
    return Target.resolve(resolved) catch |err|
        return fail("unsupported target '{s}': {t}", .{ triple, err });
}
