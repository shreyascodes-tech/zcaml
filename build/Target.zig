//! What OCaml's `configure` would decide about a target, derived from
//! `std.Target` without probing.

const std = @import("std");

const Target = @This();

zig: std.Target,
triple_buf: [64]u8,
triple_len: u8,
arch: Arch,
model: []const u8,
system: []const u8,
os_type: OsType,
libc: Libc,
/// Whether ocamlopt can emit code for this target.
native: bool,

pub const Arch = enum {
    amd64,
    arm64,
    power,
    riscv,
    s390x,
    i386,
    arm,

    pub fn hasBackend(a: Arch) bool {
        return switch (a) {
            .amd64, .arm64, .power, .riscv, .s390x => true,
            .i386, .arm => false,
        };
    }
};

pub const OsType = enum { Unix, Win32, Cygwin, None };

pub const Libc = union(enum) {
    glibc: std.SemanticVersion,
    musl,
    darwin,
    freebsd,
};

pub const ResolveError = error{UnsupportedTarget};

pub fn resolve(t: std.Target) ResolveError!Target {
    const arch: Arch, const model: []const u8 = switch (t.cpu.arch) {
        .x86_64 => .{ .amd64, "default" },
        .aarch64 => .{ .arm64, "default" },
        .riscv64 => .{ .riscv, "riscv64" },
        .powerpc64le => .{ .power, "ppc64le" },
        // configure only accepts big-endian ppc64 with musl.
        .powerpc64 => if (t.abi.isMusl()) .{ .power, "ppc64" } else return error.UnsupportedTarget,
        .s390x => .{ .s390x, "z10" },
        .x86 => .{ .i386, "default" },
        .arm => .{ .arm, "default" },
        else => return error.UnsupportedTarget,
    };

    const system: []const u8, const libc: Libc = switch (t.os.tag) {
        .linux => blk: {
            const libc: Libc = switch (t.abi) {
                .gnu, .gnueabi, .gnueabihf => .{ .glibc = t.os.version_range.linux.glibc },
                .musl, .musleabi, .musleabihf => .musl,
                else => return error.UnsupportedTarget,
            };
            break :blk .{ "linux", libc };
        },
        .macos => .{ "macosx", .darwin },
        .freebsd => .{ "freebsd", .freebsd },
        else => return error.UnsupportedTarget,
    };

    const native = arch.hasBackend() and switch (t.os.tag) {
        .linux => true,
        .macos => arch == .amd64 or arch == .arm64,
        .freebsd => arch == .amd64 or arch == .arm64,
        else => false,
    };

    var buf: [64]u8 = undefined;
    const canonical = canonicalTriple(&buf, t) catch return error.UnsupportedTarget;
    return .{
        .zig = t,
        .triple_buf = buf,
        .triple_len = @intCast(canonical.len),
        .arch = arch,
        .model = model,
        .system = system,
        .os_type = .Unix,
        .libc = libc,
        .native = native,
    };
}

/// What `config.sub` would produce, e.g. `x86_64-pc-linux-gnu`.
pub fn triple(t: *const Target) []const u8 {
    return t.triple_buf[0..t.triple_len];
}

fn canonicalTriple(buf: []u8, t: std.Target) std.fmt.BufPrintError![]const u8 {
    const cpu: []const u8 = switch (t.cpu.arch) {
        .x86 => "i686",
        else => @tagName(t.cpu.arch),
    };
    return switch (t.os.tag) {
        .linux => std.fmt.bufPrint(buf, "{s}-{s}-linux-{t}", .{
            cpu,
            switch (t.cpu.arch) {
                .x86, .x86_64 => "pc",
                .s390x => "ibm",
                else => "unknown",
            },
            t.abi,
        }),
        .macos => std.fmt.bufPrint(buf, "{s}-apple-darwin", .{cpu}),
        .freebsd => blk: {
            const v = t.os.version_range.semver.min;
            break :blk std.fmt.bufPrint(buf, "{s}-unknown-freebsd{d}.{d}", .{ cpu, v.major, v.minor });
        },
        else => unreachable,
    };
}

pub fn eql(a: *const Target, b: *const Target) bool {
    return std.mem.eql(u8, a.triple(), b.triple());
}

pub fn isDarwin(t: *const Target) bool {
    return t.zig.os.tag.isDarwin();
}

pub fn isWindows(t: *const Target) bool {
    return t.zig.os.tag == .windows;
}

pub fn ptrSize(t: *const Target) u16 {
    return t.zig.ptrBitWidth() / 8;
}

pub fn is64(t: *const Target) bool {
    return t.ptrSize() == 8;
}

/// configure's whitelist covers every target we support.
pub fn natdynlink(t: *const Target) bool {
    return t.native and t.supportsSharedLibraries();
}

pub fn supportsSharedLibraries(t: *const Target) bool {
    _ = t;
    return true;
}

pub fn functionSections(t: *const Target) bool {
    return switch (t.arch) {
        .amd64, .arm64, .power, .riscv, .s390x => !t.isDarwin() and !t.isWindows(),
        .i386, .arm => false,
    };
}

/// Only probed on 32-bit, and not on i686.
pub fn alignDouble(t: *const Target) bool {
    if (t.is64() or t.zig.cpu.arch == .x86) return false;
    return t.zig.cTypeAlignment(.double) > 4;
}

/// Only probed on 32-bit, and not on i686.
pub fn alignInt64(t: *const Target) bool {
    if (t.is64() or t.zig.cpu.arch == .x86) return false;
    if (t.zig.cTypeByteSize(.long) == 8) return t.zig.cTypeAlignment(.long) > 4;
    if (t.zig.cTypeByteSize(.longlong) == 8) return t.zig.cTypeAlignment(.longlong) > 4;
    return false;
}

pub fn archCode32(t: *const Target) bool {
    return switch (t.zig.os.tag) {
        .macos => t.arch == .amd64 or t.arch == .arm64,
        .linux => t.arch == .amd64,
        else => false,
    };
}

/// Only probed with a native compiler, and never on Windows.
pub fn asmCfiSupported(t: *const Target) bool {
    return t.native and !t.isWindows();
}

pub fn asmSizeTypeDirectives(t: *const Target) bool {
    return t.zig.ofmt == .elf;
}

pub fn nonexecstackNote(t: *const Target) bool {
    return t.zig.ofmt == .elf;
}

/// musl needs `-no-pie` when ocamlopt doesn't generate PIC.
pub fn needsNoPie(t: *const Target) bool {
    return switch (t.arch) {
        .amd64, .arm64, .s390x => false,
        else => t.libc == .musl,
    };
}

pub const Ext = struct {
    exe: []const u8,
    obj: []const u8,
    asm_: []const u8,
    lib: []const u8,
    dll: []const u8,
};

pub fn ext(t: *const Target) Ext {
    return if (t.isWindows())
        .{ .exe = ".exe", .obj = "obj", .asm_ = "asm", .lib = "lib", .dll = "dll" }
    else
        .{ .exe = "", .obj = "o", .asm_ = "s", .lib = "a", .dll = "so" };
}
