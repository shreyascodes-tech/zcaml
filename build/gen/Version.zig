//! OCaml version info, parsed from `build-aux/ocaml_version.m4`.

const std = @import("std");
const Writer = std.Io.Writer;

const Version = @This();

major: u32,
minor: u32,
patchlevel: u32,
release_number: u32,
/// Empty for official releases.
extra: []const u8,
extra_prefix: u8,
development: bool,
magic_prefix: []const u8,
magic_version: []const u8,

const ParseError = error{ MissingDefine, InvalidNumber, InvalidBool };

/// The result borrows from `contents`.
pub fn parse(contents: []const u8) ParseError!Version {
    return .{
        .major = try defineInt(contents, "OCAML__VERSION_MAJOR"),
        .minor = try defineInt(contents, "OCAML__VERSION_MINOR"),
        .patchlevel = try defineInt(contents, "OCAML__VERSION_PATCHLEVEL"),
        .release_number = try defineInt(contents, "OCAML__RELEASE_NUMBER"),
        .extra = try define(contents, "OCAML__VERSION_EXTRA"),
        .extra_prefix = blk: {
            const p = try define(contents, "OCAML__VERSION_EXTRA_PREFIX");
            break :blk if (p.len == 1) p[0] else '+';
        },
        .development = blk: {
            const d = try define(contents, "OCAML__DEVELOPMENT_VERSION");
            if (std.mem.eql(u8, d, "true")) break :blk true;
            if (std.mem.eql(u8, d, "false")) break :blk false;
            return error.InvalidBool;
        },
        .magic_prefix = try define(contents, "MAGIC_NUMBER__PREFIX"),
        .magic_version = try define(contents, "MAGIC_NUMBER__VERSION"),
    };
}

fn define(contents: []const u8, comptime name: []const u8) ParseError![]const u8 {
    const needle = "m4_define([" ++ name ++ "],";
    const start = std.mem.find(u8, contents, needle) orelse return error.MissingDefine;
    var rest = contents[start + needle.len ..];
    rest = std.mem.trimStart(u8, rest, " \t");
    if (rest.len == 0 or rest[0] != '[') return error.MissingDefine;
    const end = std.mem.findScalar(u8, rest, ']') orelse return error.MissingDefine;
    return rest[1..end];
}

fn defineInt(contents: []const u8, comptime name: []const u8) ParseError!u32 {
    const s = try define(contents, name);
    return std.fmt.parseInt(u32, s, 10) catch error.InvalidNumber;
}

pub const MagicKind = enum(u8) {
    exec = 'X',
    cmi = 'I',
    cmo = 'O',
    cma = 'A',
    cmx_clambda = 'Y',
    cmx_flambda = 'y',
    cmxa_clambda = 'Z',
    cmxa_flambda = 'z',
    ast_impl = 'M',
    ast_intf = 'N',
    cmxs = 'D',
    cmt = 'T',
    linear = 'L',
};

/// e.g. `Caml1999X037`.
pub const Magic = struct {
    v: Version,
    kind: MagicKind,

    pub fn format(m: Magic, w: *Writer) Writer.Error!void {
        try w.print("{s}{c}{s}", .{ m.v.magic_prefix, @intFromEnum(m.kind), m.v.magic_version });
    }
};

pub fn magic(v: Version, kind: MagicKind) Magic {
    return .{ .v = v, .kind = kind };
}

pub fn magicLength(v: Version) usize {
    return v.magic_prefix.len + 1 + v.magic_version.len;
}

/// e.g. "5.5.1" or "5.6.0+dev".
pub fn format(v: Version, w: *Writer) Writer.Error!void {
    try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patchlevel });
    if (v.extra.len != 0) try w.print("{c}{s}", .{ v.extra_prefix, v.extra });
}

pub fn number(v: Version) u32 {
    return v.major * 10000 + v.minor * 100 + v.patchlevel;
}

/// An OCaml expression: `None` or e.g. `Some (Plus, "dev")`.
pub const ReleaseExtra = std.fmt.Alt(Version, formatReleaseExtra);

pub fn releaseExtra(v: Version) ReleaseExtra {
    return .{ .data = v };
}

fn formatReleaseExtra(v: Version, w: *Writer) Writer.Error!void {
    if (v.extra.len == 0) return w.writeAll("None");
    const kind = if (v.extra_prefix == '+') "Plus" else "Tilde";
    try w.print("Some ({s}, \"{s}\")", .{ kind, v.extra });
}

test parse {
    const src =
        \\m4_define([OCAML__DEVELOPMENT_VERSION], [false])
        \\m4_define([OCAML__VERSION_MAJOR], [5])
        \\m4_define([OCAML__VERSION_MINOR], [5])
        \\m4_define([OCAML__RELEASE_NUMBER], [21])
        \\m4_define([OCAML__VERSION_PATCHLEVEL], [1])
        \\m4_define([OCAML__VERSION_EXTRA], [])
        \\m4_define([OCAML__VERSION_EXTRA_PREFIX], [+])
        \\m4_define([MAGIC_NUMBER__PREFIX], [Caml1999])
        \\m4_define([MAGIC_NUMBER__VERSION], [037])
    ;
    const v = try parse(src);
    try std.testing.expectEqual(@as(u32, 50501), v.number());
    try std.testing.expectEqual(@as(usize, 12), v.magicLength());
    try std.testing.expectFmt("Caml1999X037", "{f}", .{v.magic(.exec)});
    try std.testing.expectFmt("5.5.1", "{f}", .{v});
    try std.testing.expectFmt("None", "{f}", .{v.releaseExtra()});

    var dev = v;
    dev.extra = "dev";
    try std.testing.expectFmt("5.5.1+dev", "{f}", .{dev});
    try std.testing.expectFmt("Some (Plus, \"dev\")", "{f}", .{dev.releaseExtra()});
}
