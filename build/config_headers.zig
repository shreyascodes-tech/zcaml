//! C configuration headers for the runtime (what `configure` would generate).
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const Var = Source.Var;

/// `runtime/caml/m.h`: machine description.
pub fn machineH(src: Source, p: Platform) []const u8 {
    const has_code32 = (p.arch == .amd64 and (p.is_linux or p.is_macos)) or
        (p.arch == .arm64 and p.is_macos);
    const sizeof_long: []const u8 = if (p.is_windows or !p.arch64) "4" else "8";
    const sizeof_ptr: []const u8 = if (p.arch64) "8" else "4";

    const entries = [_]Var{
        .{ .name = "ARCH_SIXTYFOUR", .value = if (p.arch64) "1" else null },
        .{ .name = "ARCH_BIG_ENDIAN", .value = if (p.big_endian) "1" else null },
        .{ .name = "ARCH_ALIGN_DOUBLE", .value = if (!p.arch64) "1" else null },
        .{ .name = "HAS_ARCH_CODE32", .value = if (has_code32) "1" else null },
        .{ .name = "SIZEOF_INT", .value = "4" },
        .{ .name = "SIZEOF_LONG", .value = sizeof_long },
        .{ .name = "SIZEOF_PTR", .value = sizeof_ptr },
        .{ .name = "SIZEOF_SHORT", .value = "2" },
        .{ .name = "SIZEOF_LONGLONG", .value = "8" },
        .{ .name = "ARCH_INT64_TYPE", .value = null, .version_specific = true },
        .{ .name = "ARCH_UINT64_TYPE", .value = null, .version_specific = true },
        .{ .name = "ARCH_INT64_PRINTF_FORMAT", .value = null, .version_specific = true },
        .{ .name = "ARCH_ALIGN_INT64", .value = if (!p.arch64) "1" else null },
        .{ .name = "HEADER_RESERVED_BITS", .value = "0", .version_specific = true },
        .{ .name = "WITH_PROFINFO", .value = null, .version_specific = true },
        .{ .name = "PROFINFO_WIDTH", .value = "0", .version_specific = true },
        .{ .name = "ASM_CFI_SUPPORTED", .value = if (!p.is_windows) "1" else null },
        .{ .name = "ASM_SIZE_TYPE_DIRECTIVES", .value = if (p.is_elf) "1" else null, .version_specific = true },
        .{ .name = "WITH_FRAME_POINTERS", .value = null },
        .{ .name = "NO_NAKED_POINTERS", .value = "1" },
        .{ .name = "CAML_WITH_FPIC", .value = null, .version_specific = true },
        .{ .name = "CAML_SAFE_STRING", .value = "1" },
        .{ .name = "FLAT_FLOAT_ARRAY", .value = "1" },
        .{ .name = "FUNCTION_SECTIONS", .value = if (p.is_elf) "1" else null },
        .{ .name = "SUPPORTS_ALIGNED_ATTRIBUTE", .value = "1" },
        .{ .name = "SUPPORTS_TREE_VECTORIZE", .value = "1", .version_specific = true },
        .{ .name = "USE_MMAP_MAP_STACK", .value = if (p.resolved.result.os.tag == .openbsd) "1" else null, .version_specific = true },
        .{ .name = "WITH_NONEXECSTACK_NOTE", .value = if (p.is_linux and p.is_elf) "1" else null, .version_specific = true },
    };
    return src.renderConfigHeader("runtime/caml/m.h.in", &entries, &.{}, "");
}

/// `runtime/caml/s.h`: OS / libc capabilities.
pub fn systemH(src: Source, p: Platform) []const u8 {
    const b = src.b;
    const is_unix = !p.is_windows;
    const entries = [_]Var{
        .{ .name = "OCAML_OS_TYPE", .value = b.fmt("\"{s}\"", .{p.osType()}) },
        .{ .name = "POSIX_SIGNALS", .value = if (is_unix) "1" else null },
        .{ .name = "BSD_SIGNALS", .value = if (is_unix) "1" else null },
        .{ .name = "SUPPORT_DYNAMIC_LINKING", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_FULL_THREAD_VARIABLES", .value = if (p.is_linux or p.is_bsd) "1" else null, .version_specific = true },
        .{ .name = "HAS_C99_FLOAT_OPS", .value = "1" },
        .{ .name = "HAS_WORKING_FMA", .value = "1", .version_specific = true },
        .{ .name = "HAS_WORKING_ROUND", .value = "1", .version_specific = true },
        .{ .name = "HAS_GETENTROPY", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAS_GETRUSAGE", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_TIMES", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_STRLCPY", .value = if (p.is_macos or p.is_bsd) "1" else null, .version_specific = true },
        .{ .name = "HAS_SECURE_GETENV", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAS___SECURE_GETENV", .value = null },
        .{ .name = "HAS_ISSETUGID", .value = if (p.is_macos or p.is_bsd) "1" else null },
        .{ .name = "HAS_SYS_MMAN_H", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAS_LINUX_FUTEX_H", .value = if (p.is_linux) "1" else null, .version_specific = true },
        .{ .name = "HAS_SOCKETS", .value = "1" },
        .{ .name = "HAS_SOCKLEN_T", .value = "1", .version_specific = true },
        .{ .name = "HAS_SOCKETPAIR", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAS_AFUNIX_H", .value = if (p.is_windows) "1" else null, .version_specific = true },
        .{ .name = "HAS_INET_ATON", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_IPV6", .value = "1" },
        .{ .name = "HAS_PTHREAD_NP_H", .value = if (p.is_bsd) "1" else null, .version_specific = true },
        .{ .name = "HAS_PRCTL", .value = if (p.is_linux) "1" else null, .version_specific = true },
        .{ .name = "HAVE_PTHREAD_CANCEL", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAVE_PTHREAD_SETNAME_NP", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAVE_PTHREAD_SET_NAME_NP", .value = null, .version_specific = true },
        .{ .name = "HAS_PTHREAD_SETNAME_NP", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAS_PTHREAD_SET_NAME_NP", .value = null, .version_specific = true },
        .{ .name = "HAS_SETTHREADDESCRIPTION", .value = if (p.is_windows) "1" else null, .version_specific = true },
        .{ .name = "HAS_DECL_SETTHREADDESCRIPTION", .value = if (p.is_windows) "1" else null, .version_specific = true },
        .{ .name = "HAS_STDINT_H", .value = "1", .version_specific = true },
        .{ .name = "HAS_STDATOMIC_H", .value = "1", .version_specific = true },
        .{ .name = "HAS_UNISTD", .value = "1", .version_specific = true },
        .{ .name = "HAS_STRERROR", .value = "1", .version_specific = true },
        .{ .name = "HAS_SIGWAIT", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAS_STACK_OVERFLOW_DETECTION", .value = if (is_unix) "1" else null, .version_specific = true },
        .{ .name = "HAS_NANOSECOND_STAT", .value = if (p.is_linux) "1" else if (p.is_macos or p.is_bsd) "2" else null, .version_specific = true },
        .{ .name = "HAS_MACH_ABSOLUTE_TIME", .value = if (p.is_macos) "1" else null, .version_specific = true },
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
        .{ .name = "HAS_XLOCALE_H", .value = if (p.is_macos) "1" else null },
        .{ .name = "HAS_STRTOD_L", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_MMAP", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_PWRITE", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC", .value = if (p.is_linux) "1" else null, .version_specific = true },
        .{ .name = "HAVE_STRUCT_STAT_ST_ATIMESPEC_TV_NSEC", .value = if (p.is_macos or p.is_bsd) "1" else null, .version_specific = true },
        .{ .name = "HAVE_STRUCT_STAT_ST_ATIMENSEC", .value = null, .version_specific = true },
        .{ .name = "HAS_GETHOSTBYNAME_R", .value = if (p.is_linux) "6" else null },
        .{ .name = "HAS_GETHOSTBYADDR_R", .value = if (p.is_linux) "8" else null },
        .{ .name = "HAS_MKSTEMP", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_NICE", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_DUP3", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_PIPE2", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_ACCEPT4", .value = if (p.is_linux or p.is_bsd) "1" else null, .version_specific = true },
        .{ .name = "HAS_GETAUXVAL", .value = if (p.is_linux) "1" else null, .version_specific = true },
        .{ .name = "HAS_SYS_SHM_H", .value = if (p.is_linux or p.is_macos) "1" else null, .version_specific = true },
        .{ .name = "HAS_SHMAT", .value = if (p.is_linux or p.is_macos) "1" else null },
        .{ .name = "HAS_EXECVPE", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAS_POSIX_SPAWN", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_HUGE_PAGES", .value = null },
        .{ .name = "HUGE_PAGE_SIZE", .value = null },
        .{ .name = "HAS_LIBUNWIND", .value = null, .version_specific = true },
        .{ .name = "HAS_BROKEN_PRINTF", .value = if (p.is_windows) "1" else null },
        .{ .name = "HAS_POSIX_MONOTONIC_CLOCK", .value = if (p.is_linux or p.is_bsd) "1" else null, .version_specific = true },
        .{ .name = "HAS_CLOCK_GETTIME_NSEC_NP", .value = if (p.is_macos) "1" else null, .version_specific = true },
        .{ .name = "HAS_GNU_GETAFFINITY_NP", .value = if (p.is_linux) "1" else null },
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

    const win_footer = if (p.is_windows)
        \\
        \\/* Clang + MinGW-w64 setjmp compatibility */
        \\#define __USE_MINGW_SETJMP_NON_SEH 1
        \\#undef __MINGW64__
        \\
    else
        "";

    return src.renderConfigHeader("runtime/caml/s.h.in", &entries, &.{}, win_footer);
}

/// `runtime/caml/version.h`
pub fn versionH(src: Source) []const u8 {
    const b = src.b;
    const v = src.manifest.version;
    var entries: std.ArrayList(Var) = .empty;
    entries.appendSlice(b.allocator, &.{
        .{ .name = "OCAML_VERSION_MAJOR", .value = b.fmt("{d}", .{v.major}) },
        .{ .name = "OCAML_VERSION_MINOR", .value = b.fmt("{d}", .{v.minor}) },
        .{ .name = "OCAML_VERSION_PATCHLEVEL", .value = b.fmt("{d}", .{v.patchlevel}) },
        .{ .name = "OCAML_VERSION_ADDITIONAL", .value = if (v.extra.len > 0) b.fmt("\"{s}\"", .{v.extra}) else null },
        .{ .name = "OCAML_VERSION_EXTRA", .value = if (v.extra.len > 0) b.fmt("\"{s}{s}\"", .{ v.extra_prefix, v.extra }) else null },
        .{ .name = "OCAML_VERSION", .value = b.fmt("{d}", .{v.number}) },
        .{ .name = "OCAML_VERSION_STRING", .value = b.fmt("\"{s}\"", .{v.string}) },
    }) catch @panic("OOM");
    if (v.release_number) |rn| {
        entries.append(b.allocator, .{ .name = "OCAML_RELEASE_NUMBER", .value = b.fmt("{d}", .{rn}) }) catch @panic("OOM");
    }
    return src.renderConfigHeader("runtime/caml/version.h.in", entries.items, &.{}, "");
}

/// `runtime/caml/exec.h` (5.2+, `null` if the release has no `exec.h.in`).
pub fn execH(src: Source) ?[]const u8 {
    const b = src.b;
    const magic = src.manifest.version.magic orelse return null;
    return src.renderConfigHeader("runtime/caml/exec.h.in", &.{
        .{ .name = "EXEC_MAGIC_LENGTH", .value = b.fmt("{d}", .{magic.exec_length}) },
        .{ .name = "MAGIC_NUMBER_PREFIX", .value = b.fmt("\"{s}\"", .{magic.prefix}) },
        .{ .name = "EXEC_FORMAT", .value = b.fmt("\"{s}\"", .{magic.exec_format}) },
        .{ .name = "MAGIC_NUMBER_VERSION", .value = b.fmt("\"{s}\"", .{magic.version}) },
    }, &.{ "CAML_EXEC_H", "TRAILER_SIZE", "EXEC_MAGIC" }, "");
}

/// `runtime/build_config.h`
pub fn buildConfigH(b: *std.Build, p: Platform, stdlib_dir: []const u8, runtime_id: []const u8) []const u8 {
    const stdlib_literal = if (p.is_windows)
        b.fmt("L\"{s}\"", .{stdlib_dir})
    else
        b.fmt("\"{s}\"", .{stdlib_dir});

    return b.fmt(
        \\/* Generated by zcaml */
        \\#define OCAML_STDLIB_DIR {s}
        \\#define HOST "{s}"
        \\#define BYTECODE_RUNTIME_ID "{s}"
        \\
    , .{ stdlib_literal, p.triplet, runtime_id });
}
