const std = @import("std");
const SourceInfo = @import("source_info.zig").SourceInfo;
const OcamlVersionInfo = @import("source_info.zig").OcamlVersionInfo;

pub const TargetConfig = struct {
    resolved: std.Build.ResolvedTarget,
    arch: []const u8,
    model: []const u8,
    system: []const u8,
    os_type: []const u8,
    unix_or_win32: []const u8,
    triplet: []const u8,
    arch64: bool,
    big_endian: bool,
    is_windows: bool,
    is_macos: bool,
    is_linux: bool,
    is_bsd: bool,
    is_elf: bool,
    bytecode_runtime_id: []const u8,
    native_runtime_id: []const u8,
    zinc_runtime_id: []const u8,

    pub fn fromTarget(b: *std.Build, resolved: std.Build.ResolvedTarget, ver: OcamlVersionInfo) TargetConfig {
        const t = resolved.result;
        const arch64 = t.ptrBitWidth() == 64;
        const big_endian = t.cpu.arch.endian() == .big;
        const is_windows = t.os.tag == .windows;
        const is_macos = t.os.tag.isDarwin();
        const is_linux = t.os.tag == .linux;
        const is_bsd = switch (t.os.tag) {
            .freebsd, .openbsd, .netbsd, .dragonfly => true,
            else => false,
        };
        const is_elf = t.ofmt == .elf;

        const arch: []const u8 = switch (t.cpu.arch) {
            .x86_64 => "amd64",
            .aarch64, .aarch64_be => "arm64",
            .riscv64 => "riscv",
            .powerpc64, .powerpc64le => "power",
            .s390x => "s390x",
            .x86 => "i386",
            .arm, .armeb => "arm",
            else => "none",
        };

        const model: []const u8 = switch (t.cpu.arch) {
            .riscv64 => "riscv64",
            .powerpc64le => "ppc64le",
            .powerpc64 => "ppc64",
            .s390x => "z10",
            else => "default",
        };

        const system: []const u8 = switch (t.os.tag) {
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
        };

        const os_type: []const u8 = if (is_windows) "Win32" else "Unix";
        const unix_or_win32: []const u8 = if (is_windows) "win32" else "unix";

        const arch_str = @tagName(t.cpu.arch);
        const triplet = switch (t.os.tag) {
            .linux => b.fmt("{s}-pc-linux-{s}", .{
                arch_str,
                if (t.abi.isMusl()) "musl" else "gnu",
            }),
            .macos => b.fmt("{s}-apple-darwin", .{arch_str}),
            .windows => if (t.abi == .msvc)
                b.fmt("{s}-pc-windows", .{arch_str})
            else
                b.fmt("{s}-w64-mingw32", .{arch_str}),
            .freebsd => b.fmt("{s}-unknown-freebsd", .{arch_str}),
            .openbsd => b.fmt("{s}-unknown-openbsd", .{arch_str}),
            .netbsd => b.fmt("{s}-unknown-netbsd", .{arch_str}),
            else => b.fmt("{s}-unknown-{s}", .{ arch_str, @tagName(t.os.tag) }),
        };

        // Compute Runtime IDs using configure.ac's exact base32 formula (OCaml 5.5+)
        const alphabet = "0123456789abcdefghijklmnopqrstuv";
        const runtime_id = if (ver.release_number) |rn| blk: {
            const id_version: u32 = (rn << 1) + @as(u32, if (ver.dev_version) 1 else 0);
            const q0 = alphabet[id_version & 31];
            const q1 = alphabet[(id_version >> 5) & 31]; // reserved_header_bits = 0
            const q2 = alphabet[0]; // flat_float_array = true, frame_pointers = false, tsan = false
            const q3 = alphabet[@as(u32, if (arch64) 0 else 1)]; // supports_shared = true, zstd = ok, windows_unicode = 1
            break :blk b.fmt("{c}{c}{c}{c}", .{ q0, q1, q2, q3 });
        } else "";

        return .{
            .resolved = resolved,
            .arch = arch,
            .model = model,
            .system = system,
            .os_type = os_type,
            .unix_or_win32 = unix_or_win32,
            .triplet = triplet,
            .arch64 = arch64,
            .big_endian = big_endian,
            .is_windows = is_windows,
            .is_macos = is_macos,
            .is_linux = is_linux,
            .is_bsd = is_bsd,
            .is_elf = is_elf,
            .bytecode_runtime_id = runtime_id,
            .native_runtime_id = runtime_id,
            .zinc_runtime_id = runtime_id,
        };
    }

    pub fn runtimeAsmFile(self: TargetConfig) ?[]const u8 {
        if (self.is_windows and self.resolved.result.abi == .msvc) {
            if (std.mem.eql(u8, self.arch, "amd64")) return "amd64nt.asm";
            return null;
        }
        if (std.mem.eql(u8, self.arch, "amd64")) return "amd64.S";
        if (std.mem.eql(u8, self.arch, "arm64")) return "arm64.S";
        if (std.mem.eql(u8, self.arch, "riscv")) return "riscv.S";
        if (std.mem.eql(u8, self.arch, "power")) return "power.S";
        if (std.mem.eql(u8, self.arch, "s390x")) return "s390x.S";
        return null;
    }

    pub fn generateMH(self: TargetConfig, b: *std.Build, src_info: SourceInfo) []const u8 {
        const has_code32 = (std.mem.eql(u8, self.arch, "amd64") and (self.is_linux or self.is_macos)) or
            (std.mem.eql(u8, self.arch, "arm64") and self.is_macos);
        const sizeof_long: []const u8 = if (self.is_windows or !self.arch64) "4" else "8";
        const sizeof_ptr: []const u8 = if (self.arch64) "8" else "4";

        const entries = [_]SourceInfo.MacroEntry{
            .{ .name = "ARCH_SIXTYFOUR", .value = if (self.arch64) "1" else null },
            .{ .name = "ARCH_BIG_ENDIAN", .value = if (self.big_endian) "1" else null },
            .{ .name = "ARCH_ALIGN_DOUBLE", .value = if (!self.arch64) "1" else null },
            .{ .name = "HAS_ARCH_CODE32", .value = if (has_code32) "1" else null },
            .{ .name = "SIZEOF_INT", .value = "4" },
            .{ .name = "SIZEOF_LONG", .value = sizeof_long },
            .{ .name = "SIZEOF_PTR", .value = sizeof_ptr },
            .{ .name = "SIZEOF_SHORT", .value = "2" },
            .{ .name = "SIZEOF_LONGLONG", .value = "8" },
            .{ .name = "ARCH_INT64_TYPE", .value = null, .version_specific = true },
            .{ .name = "ARCH_UINT64_TYPE", .value = null, .version_specific = true },
            .{ .name = "ARCH_INT64_PRINTF_FORMAT", .value = null, .version_specific = true },
            .{ .name = "ARCH_ALIGN_INT64", .value = if (!self.arch64) "1" else null },
            .{ .name = "HEADER_RESERVED_BITS", .value = "0", .version_specific = true },
            .{ .name = "WITH_PROFINFO", .value = null, .version_specific = true },
            .{ .name = "PROFINFO_WIDTH", .value = "0", .version_specific = true },
            .{ .name = "ASM_CFI_SUPPORTED", .value = if (!self.is_windows) "1" else null },
            .{ .name = "ASM_SIZE_TYPE_DIRECTIVES", .value = if (self.is_elf) "1" else null, .version_specific = true },
            .{ .name = "WITH_FRAME_POINTERS", .value = null },
            .{ .name = "NO_NAKED_POINTERS", .value = "1" },
            .{ .name = "CAML_WITH_FPIC", .value = null, .version_specific = true },
            .{ .name = "CAML_SAFE_STRING", .value = "1" },
            .{ .name = "FLAT_FLOAT_ARRAY", .value = "1" },
            .{ .name = "FUNCTION_SECTIONS", .value = if (self.is_elf) "1" else null },
            .{ .name = "SUPPORTS_ALIGNED_ATTRIBUTE", .value = "1" },
            .{ .name = "SUPPORTS_TREE_VECTORIZE", .value = "1", .version_specific = true },
            .{ .name = "USE_MMAP_MAP_STACK", .value = if (self.resolved.result.os.tag == .openbsd) "1" else null, .version_specific = true },
            .{ .name = "WITH_NONEXECSTACK_NOTE", .value = if (self.is_linux and self.is_elf) "1" else null, .version_specific = true },
        };
        _ = b;
        return src_info.renderConfigHeaderTemplate("runtime/caml/m.h.in", &entries, &.{}, "");
    }

    pub fn generateSH(self: TargetConfig, b: *std.Build, src_info: SourceInfo) []const u8 {
        const is_unix = !self.is_windows;
        const entries = [_]SourceInfo.MacroEntry{
            .{ .name = "OCAML_OS_TYPE", .value = b.fmt("\"{s}\"", .{self.os_type}) },
            .{ .name = "POSIX_SIGNALS", .value = if (is_unix) "1" else null },
            .{ .name = "BSD_SIGNALS", .value = if (is_unix) "1" else null },
            .{ .name = "SUPPORT_DYNAMIC_LINKING", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_FULL_THREAD_VARIABLES", .value = if (self.is_linux or self.is_bsd) "1" else null, .version_specific = true },
            .{ .name = "HAS_C99_FLOAT_OPS", .value = "1" },
            .{ .name = "HAS_WORKING_FMA", .value = "1", .version_specific = true },
            .{ .name = "HAS_WORKING_ROUND", .value = "1", .version_specific = true },
            .{ .name = "HAS_GETENTROPY", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_GETRUSAGE", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_TIMES", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_STRLCPY", .value = if (self.is_macos or self.is_bsd) "1" else null, .version_specific = true },
            .{ .name = "HAS_SECURE_GETENV", .value = if (self.is_linux) "1" else null },
            .{ .name = "HAS___SECURE_GETENV", .value = null },
            .{ .name = "HAS_ISSETUGID", .value = if (self.is_macos or self.is_bsd) "1" else null },
            .{ .name = "HAS_SYS_MMAN_H", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_LINUX_FUTEX_H", .value = if (self.is_linux) "1" else null, .version_specific = true },
            .{ .name = "HAS_SOCKETS", .value = "1" },
            .{ .name = "HAS_SOCKLEN_T", .value = "1", .version_specific = true },
            .{ .name = "HAS_SOCKETPAIR", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_AFUNIX_H", .value = if (self.is_windows) "1" else null, .version_specific = true },
            .{ .name = "HAS_INET_ATON", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_IPV6", .value = "1" },
            .{ .name = "HAS_PTHREAD_NP_H", .value = if (self.is_bsd) "1" else null, .version_specific = true },
            .{ .name = "HAS_PRCTL", .value = if (self.is_linux) "1" else null, .version_specific = true },
            .{ .name = "HAVE_PTHREAD_CANCEL", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_PTHREAD_SETNAME_NP", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_PTHREAD_SET_NAME_NP", .value = null, .version_specific = true },
            .{ .name = "HAS_PTHREAD_SETNAME_NP", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_PTHREAD_SET_NAME_NP", .value = null, .version_specific = true },
            .{ .name = "HAS_SETTHREADDESCRIPTION", .value = if (self.is_windows) "1" else null, .version_specific = true },
            .{ .name = "HAS_DECL_SETTHREADDESCRIPTION", .value = if (self.is_windows) "1" else null, .version_specific = true },
            .{ .name = "HAS_STDINT_H", .value = "1", .version_specific = true },
            .{ .name = "HAS_STDATOMIC_H", .value = "1", .version_specific = true },
            .{ .name = "HAS_UNISTD", .value = "1", .version_specific = true },
            .{ .name = "HAS_STRERROR", .value = "1", .version_specific = true },
            .{ .name = "HAS_SIGWAIT", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_STACK_OVERFLOW_DETECTION", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_NANOSECOND_STAT", .value = if (self.is_linux) "1" else if (self.is_macos or self.is_bsd) "2" else null, .version_specific = true },
            .{ .name = "HAS_MACH_ABSOLUTE_TIME", .value = if (self.is_macos) "1" else null, .version_specific = true },
            .{ .name = "HAS_BITSCANFORWARD", .value = null, .version_specific = true },
            .{ .name = "HAS_FFS", .value = null, .version_specific = true },
            .{ .name = "HAS_LIBGEN_H", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_DIRENT", .value = "1" },
            .{ .name = "HAS_REWINDDIR", .value = "1" },
            .{ .name = "HAS_LOCKF", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_MKFIFO", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_GETCWD", .value = "1" },
            .{ .name = "HAS_SYSTEM", .value = "1" },
            .{ .name = "HAS_UTIME", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_UTIMES", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_FCHMOD", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_TRUNCATE", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_SELECT", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_SYS_SELECT_H", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_NANOSLEEP", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_SYMLINK", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_REALPATH", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_WAIT4", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_WAITPID", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_GETGROUPS", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_SETGROUPS", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_INITGROUPS", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_TERMIOS", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_SETITIMER", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_GETHOSTNAME", .value = "1" },
            .{ .name = "HAS_UNAME", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_GETTIMEOFDAY", .value = "1" },
            .{ .name = "HAS_MKTIME", .value = "1" },
            .{ .name = "HAVE_GMTIME_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_LOCALTIME_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAS_SETSID", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_PUTENV", .value = "1" },
            .{ .name = "HAS_SETENV_UNSETENV", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_LOCALE_H", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_XLOCALE_H", .value = if (self.is_macos) "1" else null },
            .{ .name = "HAS_STRTOD_L", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_MMAP", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_PWRITE", .value = if (is_unix) "1" else null },
            .{ .name = "HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC", .value = if (self.is_linux) "1" else null, .version_specific = true },
            .{ .name = "HAVE_STRUCT_STAT_ST_ATIMESPEC_TV_NSEC", .value = if (self.is_macos or self.is_bsd) "1" else null, .version_specific = true },
            .{ .name = "HAVE_STRUCT_STAT_ST_ATIMENSEC", .value = null, .version_specific = true },
            .{ .name = "HAS_GETHOSTBYNAME_R", .value = if (self.is_linux) "6" else null },
            .{ .name = "HAS_GETHOSTBYADDR_R", .value = if (self.is_linux) "8" else null },
            .{ .name = "HAS_MKSTEMP", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_NICE", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_DUP3", .value = if (self.is_linux or self.is_bsd) "1" else null },
            .{ .name = "HAS_PIPE2", .value = if (self.is_linux or self.is_bsd) "1" else null },
            .{ .name = "HAS_ACCEPT4", .value = if (self.is_linux or self.is_bsd) "1" else null, .version_specific = true },
            .{ .name = "HAS_GETAUXVAL", .value = if (self.is_linux) "1" else null, .version_specific = true },
            .{ .name = "HAS_SYS_SHM_H", .value = if (self.is_linux or self.is_macos) "1" else null, .version_specific = true },
            .{ .name = "HAS_SHMAT", .value = if (self.is_linux or self.is_macos) "1" else null },
            .{ .name = "HAS_EXECVPE", .value = if (self.is_linux) "1" else null },
            .{ .name = "HAS_POSIX_SPAWN", .value = if (is_unix) "1" else null },
            .{ .name = "HAS_HUGE_PAGES", .value = null },
            .{ .name = "HUGE_PAGE_SIZE", .value = null },
            .{ .name = "HAS_LIBUNWIND", .value = null, .version_specific = true },
            .{ .name = "HAS_BROKEN_PRINTF", .value = if (self.is_windows) "1" else null },
            .{ .name = "HAS_POSIX_MONOTONIC_CLOCK", .value = if (self.is_linux or self.is_bsd) "1" else null, .version_specific = true },
            .{ .name = "HAS_CLOCK_GETTIME_NSEC_NP", .value = if (self.is_macos) "1" else null, .version_specific = true },
            .{ .name = "HAS_GNU_GETAFFINITY_NP", .value = if (self.is_linux) "1" else null },
            .{ .name = "HAS_BSD_GETAFFINITY_NP", .value = null },
            .{ .name = "HAS_ZSTD", .value = "1", .version_specific = true },
            .{ .name = "HAVE_MAX_ALIGN_T", .value = "1", .version_specific = true },
            .{ .name = "HAVE_GETGRNAM_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_GETGRGID_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_GETPWNAM_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_GETPWUID_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_GETLOGIN_R", .value = if (is_unix) "1" else null, .version_specific = true },
            .{ .name = "HAVE_LABELS_AS_VALUES", .value = "1", .version_specific = true },
            .{ .name = "HAVE___TSAN_FUNC_EXIT_VOID_VOID_P", .value = null, .version_specific = true },
            .{ .name = "HAVE___TSAN_FUNC_EXIT_VOID_VOID", .value = null, .version_specific = true },
        };

        const win_footer = if (self.is_windows)
            \\
            \\/* Clang + MinGW-w64 setjmp compatibility */
            \\#define __USE_MINGW_SETJMP_NON_SEH 1
            \\#undef __MINGW64__
            \\
        else
            "";

        return src_info.renderConfigHeaderTemplate("runtime/caml/s.h.in", &entries, &.{}, win_footer);
    }

    pub fn generateVersionH(b: *std.Build, src_info: SourceInfo) []const u8 {
        const v = src_info.version;
        var entries: std.ArrayList(SourceInfo.MacroEntry) = .empty;
        entries.appendSlice(b.allocator, &.{
            .{ .name = "OCAML_VERSION_MAJOR", .value = b.fmt("{d}", .{v.major}) },
            .{ .name = "OCAML_VERSION_MINOR", .value = b.fmt("{d}", .{v.minor}) },
            .{ .name = "OCAML_VERSION_PATCHLEVEL", .value = b.fmt("{d}", .{v.patchlevel}) },
            .{ .name = "OCAML_VERSION_ADDITIONAL", .value = if (v.extra.len > 0) b.fmt("\"{s}\"", .{v.extra}) else null },
            .{ .name = "OCAML_VERSION_EXTRA", .value = if (v.extra.len > 0) b.fmt("\"{s}{s}\"", .{ v.extra_prefix, v.extra }) else null },
            .{ .name = "OCAML_VERSION", .value = b.fmt("{d}", .{v.version_number}) },
            .{ .name = "OCAML_VERSION_STRING", .value = b.fmt("\"{s}\"", .{v.version_string}) },
        }) catch @panic("OOM");
        if (v.release_number) |rn| {
            entries.append(b.allocator, .{
                .name = "OCAML_RELEASE_NUMBER",
                .value = b.fmt("{d}", .{rn}),
            }) catch @panic("OOM");
        }
        return src_info.renderConfigHeaderTemplate("runtime/caml/version.h.in", entries.items, &.{}, "");
    }

    pub fn generateExecH(b: *std.Build, src_info: SourceInfo) ?[]const u8 {
        const v = src_info.version;
        const magic_len = v.exec_magic_length orelse return null;
        const entries = [_]SourceInfo.MacroEntry{
            .{ .name = "EXEC_MAGIC_LENGTH", .value = b.fmt("{d}", .{magic_len}) },
            .{ .name = "MAGIC_NUMBER_PREFIX", .value = b.fmt("\"{s}\"", .{v.magic_prefix.?}) },
            .{ .name = "EXEC_FORMAT", .value = b.fmt("\"{s}\"", .{v.exec_format.?}) },
            .{ .name = "MAGIC_NUMBER_VERSION", .value = b.fmt("\"{s}\"", .{v.magic_version.?}) },
        };
        const ignored_defines = [_][]const u8{
            "CAML_EXEC_H",
            "TRAILER_SIZE",
            "EXEC_MAGIC",
        };
        return src_info.renderConfigHeaderTemplate("runtime/caml/exec.h.in", &entries, &ignored_defines, "");
    }

    pub fn generateBuildConfigH(self: TargetConfig, b: *std.Build, stdlib_dir: []const u8) []const u8 {
        const stdlib_literal = if (self.is_windows)
            b.fmt("L\"{s}\"", .{stdlib_dir})
        else
            b.fmt("\"{s}\"", .{stdlib_dir});

        return b.fmt(
            \\/* Generated by zcaml */
            \\#define OCAML_STDLIB_DIR {s}
            \\#define HOST "{s}"
            \\#define BYTECODE_RUNTIME_ID "{s}"
            \\
        , .{ stdlib_literal, self.triplet, self.bytecode_runtime_id });
    }
};

pub fn resolveTarget(b: *std.Build, target_str: []const u8) std.Build.ResolvedTarget {
    if (std.mem.eql(u8, target_str, "native") or std.mem.eql(u8, target_str, "host")) {
        return b.graph.host;
    }

    // Normalize common autoconf triplets into Zig triples if needed
    const normalized = normalizeTriplet(b, target_str);
    const query = std.Target.Query.parse(.{
        .arch_os_abi = normalized,
    }) catch |err| {
        std.debug.panic("Invalid target '{s}' (normalized: '{s}'): {t}", .{ target_str, normalized, err });
    };

    return b.resolveTargetQuery(query);
}

fn normalizeTriplet(b: *std.Build, str: []const u8) []const u8 {
    if (std.mem.eql(u8, str, "x86_64-pc-linux-gnu") or std.mem.eql(u8, str, "x86_64-unknown-linux-gnu")) {
        return "x86_64-linux-gnu";
    }
    if (std.mem.eql(u8, str, "x86_64-pc-linux-musl") or std.mem.eql(u8, str, "x86_64-unknown-linux-musl")) {
        return "x86_64-linux-musl";
    }
    if (std.mem.eql(u8, str, "aarch64-unknown-linux-gnu") or std.mem.eql(u8, str, "aarch64-linux-gnu")) {
        return "aarch64-linux-gnu";
    }
    if (std.mem.eql(u8, str, "aarch64-unknown-linux-musl") or std.mem.eql(u8, str, "aarch64-linux-musl")) {
        return "aarch64-linux-musl";
    }
    if (std.mem.eql(u8, str, "aarch64-apple-darwin") or std.mem.eql(u8, str, "arm64-apple-darwin")) {
        return "aarch64-macos";
    }
    if (std.mem.eql(u8, str, "x86_64-apple-darwin")) {
        return "x86_64-macos";
    }
    if (std.mem.eql(u8, str, "x86_64-w64-mingw32")) {
        return "x86_64-windows-gnu";
    }
    if (std.mem.eql(u8, str, "x86_64-pc-windows")) {
        return "x86_64-windows-msvc";
    }
    _ = b;
    return str;
}
