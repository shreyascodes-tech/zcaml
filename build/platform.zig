//! What OCaml needs to know about a machine (build, compiler host or target).
const std = @import("std");
const Manifest = @import("manifests/manifest.zig");
pub const Arch = Manifest.Arch;

const Platform = @This();

resolved: std.Build.ResolvedTarget,
/// Native-code backend, `null` if OCaml has none for this CPU (bytecode only).
arch: ?Arch,
model: []const u8,
system: []const u8,
/// Autoconf-style triplet, e.g. `x86_64-pc-linux-gnu`.
triplet: []const u8,
arch64: bool,
big_endian: bool,
is_windows: bool,
is_macos: bool,
is_linux: bool,
is_bsd: bool,
is_elf: bool,
c: CConfig,

pub fn init(b: *std.Build, resolved: std.Build.ResolvedTarget) Platform {
    const t = resolved.result;
    const is_windows = t.os.tag == .windows;
    const is_linux = t.os.tag == .linux;

    const arch: ?Arch = switch (t.cpu.arch) {
        .x86_64 => .amd64,
        .aarch64, .aarch64_be => .arm64,
        .riscv64 => .riscv,
        .powerpc64, .powerpc64le => .power,
        .s390x => .s390x,
        .x86 => .i386,
        .arm, .armeb => .arm,
        else => null,
    };

    const arch_str = @tagName(t.cpu.arch);
    return .{
        .resolved = resolved,
        .arch = arch,
        .model = switch (t.cpu.arch) {
            .riscv64 => "riscv64",
            .powerpc64le => "ppc64le",
            .powerpc64 => "ppc64",
            .s390x => "z10",
            else => "default",
        },
        .system = switch (t.os.tag) {
            .linux => "linux",
            .macos, .ios, .tvos, .watchos, .visionos => "macosx",
            .windows => if (t.abi == .msvc) "win64" else "mingw64",
            .freebsd => "freebsd",
            .openbsd => "openbsd",
            .netbsd => "netbsd",
            .dragonfly => "dragonfly",
            .illumos => "solaris",
            .haiku => "beos",
            else => "unknown",
        },
        .triplet = switch (t.os.tag) {
            .linux => b.fmt("{s}-pc-linux-{s}", .{ arch_str, if (t.abi.isMusl()) "musl" else "gnu" }),
            .macos => b.fmt("{s}-apple-darwin", .{arch_str}),
            .windows => if (t.abi == .msvc)
                b.fmt("{s}-pc-windows", .{arch_str})
            else
                b.fmt("{s}-w64-mingw32", .{arch_str}),
            .freebsd => b.fmt("{s}-unknown-freebsd", .{arch_str}),
            .openbsd => b.fmt("{s}-unknown-openbsd", .{arch_str}),
            .netbsd => b.fmt("{s}-unknown-netbsd", .{arch_str}),
            else => b.fmt("{s}-unknown-{s}", .{ arch_str, @tagName(t.os.tag) }),
        },
        .arch64 = t.ptrBitWidth() == 64,
        .big_endian = t.cpu.arch.endian() == .big,
        .is_windows = is_windows,
        .is_macos = t.os.tag.isDarwin(),
        .is_linux = is_linux,
        .is_bsd = switch (t.os.tag) {
            .freebsd, .openbsd, .netbsd, .dragonfly => true,
            else => false,
        },
        .is_elf = t.ofmt == .elf,
        .c = .init(t),
    };
}

pub fn eql(a: Platform, b: Platform) bool {
    return std.mem.eql(u8, a.triplet, b.triplet);
}

/// `amd64`, ..., or `none` (OCaml's `ARCH`).
pub fn archName(self: Platform) []const u8 {
    return if (self.arch) |a| @tagName(a) else "none";
}

pub fn unixOrWin32(self: Platform) []const u8 {
    return if (self.is_windows) "win32" else "unix";
}

pub fn osType(self: Platform) []const u8 {
    return if (self.is_windows) "Win32" else "Unix";
}

pub fn exeExt(self: Platform) []const u8 {
    return if (self.is_windows) ".exe" else "";
}

/// Without the dot.
pub fn dllExt(self: Platform) []const u8 {
    return if (self.is_windows) "dll" else "so";
}

/// Native runtime assembly file in `runtime/`, `null` if there is no native backend.
pub fn runtimeAsmFile(self: Platform) ?[]const u8 {
    if (self.is_windows and self.resolved.result.abi == .msvc) {
        return if (self.arch == .amd64) "amd64nt.asm" else null;
    }
    return switch (self.arch orelse return null) {
        .amd64 => "amd64.S",
        .arm64 => "arm64.S",
        .riscv => "riscv.S",
        .power => "power.S",
        .s390x => "s390x.S",
        .i386, .arm => null,
    };
}

pub fn hasNativeCompiler(self: Platform) bool {
    return self.runtimeAsmFile() != null;
}

/// `-D` flags for C code compiled into the native runtime / native stub libraries.
pub fn nativeDefines(self: Platform, b: *std.Build) []const []const u8 {
    return b.allocator.dupe([]const u8, &.{
        "-DNATIVE_CODE",
        b.fmt("-DTARGET_{s}", .{self.archName()}),
        b.fmt("-DMODEL_{s}", .{self.model}),
        b.fmt("-DSYS_{s}", .{self.system}),
    }) catch @panic("OOM");
}

/// Runtime ID used to name versioned runtimes (`ocamlrun-<id>`), 5.5+.
/// Mirrors the base32 computation in `configure.ac`.
pub fn runtimeId(self: Platform, b: *std.Build, version: Manifest.Version) []const u8 {
    const rn = version.release_number orelse return "";
    const alphabet = "0123456789abcdefghijklmnopqrstuv";
    const id_version: u32 = (rn << 1) + @intFromBool(version.dev);
    return b.fmt("{c}{c}{c}{c}", .{
        alphabet[id_version & 31],
        alphabet[(id_version >> 5) & 31], // reserved_header_bits = 0
        alphabet[0], // flat_float_array = true, frame_pointers = false, tsan = false
        alphabet[@intFromBool(!self.arch64)], // supports_shared = true, zstd = ok, windows_unicode = 1
    });
}

/// How C code is compiled and linked for this platform. Used both to build the
/// runtime / stubs with Zig and to fill in `Config` (`ocamlc -config`), so the C
/// code users compile through `ocamlc`/`ocamlopt` sees the same configuration.
pub const CConfig = struct {
    /// `OC_CFLAGS`
    cflags: []const []const u8,
    /// `OC_CPPFLAGS`
    cppflags: []const []const u8,
    /// System libraries every OCaml executable links against (`-l<name>`).
    libs: []const []const u8,

    pub fn init(t: std.Target) CConfig {
        const is_windows = t.os.tag == .windows;
        return .{
            .cflags = if (is_windows)
                &.{ "-O2", "-fno-strict-aliasing", "-fwrapv", "-mms-bitfields" }
            else
                &.{ "-O2", "-fno-strict-aliasing", "-fwrapv", "-pthread" },
            .cppflags = if (is_windows)
                &.{ "-D__USE_MINGW_ANSI_STDIO=0", "-DUNICODE", "-D_UNICODE", "-DWINDOWS_UNICODE=1" }
            else
                &.{"-D_FILE_OFFSET_BITS=64"},
            .libs = if (is_windows)
                &.{ "ws2_32", "advapi32", "ole32", "uuid", "version", "shlwapi", "api-ms-win-core-synch-l1-2-0" }
            else if (t.os.tag == .linux)
                &.{ "m", "dl", "pthread" }
            else
                &.{ "m", "pthread" },
        };
    }

    /// Flags for compiling OCaml's C sources with Zig: `cflags ++ cppflags ++ extra`.
    pub fn flags(self: CConfig, b: *std.Build, extra: []const []const u8) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        out.appendSlice(b.allocator, self.cflags) catch @panic("OOM");
        out.appendSlice(b.allocator, self.cppflags) catch @panic("OOM");
        // zig cc enables UBSan in debug modes; OCaml's runtime relies on wrapping arithmetic etc.
        out.append(b.allocator, "-fno-sanitize=undefined") catch @panic("OOM");
        out.appendSlice(b.allocator, extra) catch @panic("OOM");
        return out.items;
    }

    pub fn linkLibs(self: CConfig, mod: *std.Build.Module) void {
        for (self.libs) |l| mod.linkSystemLibrary(l, .{});
    }

    /// `-lm -ldl -lpthread`
    pub fn libsString(self: CConfig, b: *std.Build) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.libs, 0..) |l, i| {
            if (i > 0) out.append(b.allocator, ' ') catch @panic("OOM");
            out.print(b.allocator, "-l{s}", .{l}) catch @panic("OOM");
        }
        return out.items;
    }

    pub fn cflagsString(self: CConfig, b: *std.Build) []const u8 {
        return std.mem.join(b.allocator, " ", self.cflags) catch @panic("OOM");
    }

    pub fn cppflagsString(self: CConfig, b: *std.Build) []const u8 {
        return std.mem.join(b.allocator, " ", self.cppflags) catch @panic("OOM");
    }
};

/// Parse `native`/`host` or a Zig / autoconf target triple.
pub fn resolveTarget(b: *std.Build, target_str: []const u8) std.Build.ResolvedTarget {
    if (std.mem.eql(u8, target_str, "native") or std.mem.eql(u8, target_str, "host")) {
        return b.graph.host;
    }

    const normalized = normalizeTriplet(target_str);
    const query = std.Target.Query.parse(.{ .arch_os_abi = normalized }) catch |err| {
        std.debug.panic("Invalid target '{s}' (normalized: '{s}'): {t}", .{ target_str, normalized, err });
    };
    return b.resolveTargetQuery(query);
}

/// Map common autoconf triplets to Zig triples.
fn normalizeTriplet(str: []const u8) []const u8 {
    inline for (&.{
        .{ "x86_64-pc-linux-gnu", "x86_64-linux-gnu" },
        .{ "x86_64-unknown-linux-gnu", "x86_64-linux-gnu" },
        .{ "x86_64-pc-linux-musl", "x86_64-linux-musl" },
        .{ "x86_64-unknown-linux-musl", "x86_64-linux-musl" },
        .{ "aarch64-unknown-linux-gnu", "aarch64-linux-gnu" },
        .{ "aarch64-unknown-linux-musl", "aarch64-linux-musl" },
        .{ "aarch64-apple-darwin", "aarch64-macos" },
        .{ "arm64-apple-darwin", "aarch64-macos" },
        .{ "x86_64-apple-darwin", "x86_64-macos" },
        .{ "x86_64-w64-mingw32", "x86_64-windows-gnu" },
        .{ "x86_64-pc-windows", "x86_64-windows-msvc" },
    }) |entry| {
        if (std.mem.eql(u8, str, entry[0])) return entry[1];
    }
    return str;
}
