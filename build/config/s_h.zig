const std = @import("std");
const State = @import("../state.zig");
const Config = @import("static.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(state: *State) LazyPath {
    const target = &state.target.result;
    State.requireLinuxTarget("s_h.zig", target);

    const is_gnu = target.isGnuLibC();
    const is_musl = target.isMuslLibC();

    // GNU target triples carry the minimum glibc version.  Keep an unknown
    // version conservative: without a version, use only the bundled musl
    // surface.  These are libc API availability checks, not compiler probes.
    const glibc_version = if (is_gnu)
        target.os.versionRange().gnuLibCVersion()
    else
        null;

    const has_c99_float_ops = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 1, .patch = 0 });
    const has_working_fma = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 1, .patch = 0 });
    const has_working_round = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 1, .patch = 0 });
    const has_getentropy = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 25, .patch = 0 });
    const has_strlcpy = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 38, .patch = 0 });
    const has_secure_getenv = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 17, .patch = 0 });
    const has_underscore_secure_getenv = is_gnu and
        gnuLibCAtLeast(glibc_version, .{ .major = 2, .minor = 0, .patch = 0 }) and
        !has_secure_getenv;
    const has_pthread_setname_np = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 12, .patch = 0 });
    const has_strtod_l = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 3, .patch = 0 });
    const has_stat_nsec = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 12, .patch = 0 });
    const has_dup3 = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 9, .patch = 0 });
    const has_pipe2 = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 9, .patch = 0 });
    const has_accept4 = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 10, .patch = 0 });
    const has_getauxval = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 16, .patch = 0 });
    const has_execvpe = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 11, .patch = 0 });
    const has_posix_spawn = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 2, .patch = 0 });
    const has_posix_monotonic_clock = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 17, .patch = 0 });
    const has_gnu_getaffinity_np = libcHasFeature(is_musl, glibc_version, .{ .major = 2, .minor = 3, .patch = 4 });

    // This is a fixed description of the Zig 0.16 Linux libc surface, not a
    // set of configure probes.  Keep APIs that depend on a target-specific
    // probe (for example huge pages) off; zstd is supplied by the build.
    return tools.configHeader(
        state.b,
        state.ocamlRel("runtime/caml/s.h.in"),
        &.{
            .{ "OCAML_OS_TYPE", .str(Config.config.os_type_unix) },
            .{ "POSIX_SIGNALS", .flagOrNull(true) },
            .{ "BSD_SIGNALS", .flagOrNull(false) },
            .{ "SUPPORT_DYNAMIC_LINKING", .flagOrNull(true) },
            .{ "HAS_FULL_THREAD_VARIABLES", .flagOrNull(true) },
            .{ "HAS_C99_FLOAT_OPS", .flagOrNull(has_c99_float_ops) },
            .{ "HAS_WORKING_FMA", .flagOrNull(has_working_fma) },
            .{ "HAS_WORKING_ROUND", .flagOrNull(has_working_round) },
            .{ "HAS_GETENTROPY", .flagOrNull(has_getentropy) },
            .{ "HAS_GETRUSAGE", .flagOrNull(true) },
            .{ "HAS_TIMES", .flagOrNull(true) },
            // The APIs below are available in the musl bundled with Zig.  GNU
            // builds use the target's glibc floor and otherwise take OCaml's
            // portable fallback path.
            .{ "HAS_STRLCPY", .flagOrNull(has_strlcpy) },
            .{ "HAS_SECURE_GETENV", .flagOrNull(has_secure_getenv) },
            .{ "HAS___SECURE_GETENV", .flagOrNull(has_underscore_secure_getenv) },
            .{ "HAS_ISSETUGID", .flagOrNull(false) },
            .{ "HAS_SYS_MMAN_H", .flagOrNull(true) },
            .{ "HAS_LINUX_FUTEX_H", .flagOrNull(true) },
            .{ "HAS_SOCKETS", .flagOrNull(true) },
            // These are not needed by the Unix runtime and are primarily
            // Windows or BSD compatibility switches.
            .{ "HAS_SOCKETPAIR", .flagOrNull(false) },
            .{ "HAS_AFUNIX_H", .flagOrNull(false) },
            .{ "HAS_INET_ATON", .flagOrNull(true) },
            .{ "HAS_IPV6", .flagOrNull(true) },
            .{ "HAS_PTHREAD_NP_H", .flagOrNull(false) },
            .{ "HAS_PRCTL", .flagOrNull(true) },
            .{ "HAVE_PTHREAD_CANCEL", .flagOrNull(true) },
            .{ "HAVE_PTHREAD_SETNAME_NP", .flagOrNull(has_pthread_setname_np) },
            .{ "HAVE_PTHREAD_SET_NAME_NP", .flagOrNull(false) },
            .{ "HAS_SETTHREADDESCRIPTION", .flagOrNull(false) },
            .{ "HAS_DECL_SETTHREADDESCRIPTION", .flagOrNull(false) },
            .{ "HAS_LIBGEN_H", .flagOrNull(true) },
            .{ "HAS_DIRENT", .flagOrNull(true) },
            .{ "HAS_REWINDDIR", .flagOrNull(true) },
            .{ "HAS_LOCKF", .flagOrNull(true) },
            .{ "HAS_MKFIFO", .flagOrNull(true) },
            .{ "HAS_GETCWD", .flagOrNull(true) },
            .{ "HAS_SYSTEM", .flagOrNull(true) },
            .{ "HAS_UTIME", .flagOrNull(true) },
            .{ "HAS_UTIMES", .flagOrNull(true) },
            .{ "HAS_FCHMOD", .flagOrNull(true) },
            .{ "HAS_TRUNCATE", .flagOrNull(true) },
            .{ "HAS_SELECT", .flagOrNull(true) },
            .{ "HAS_SYS_SELECT_H", .flagOrNull(true) },
            .{ "HAS_NANOSLEEP", .flagOrNull(true) },
            .{ "HAS_SYMLINK", .flagOrNull(true) },
            .{ "HAS_REALPATH", .flagOrNull(true) },
            .{ "HAS_WAIT4", .flagOrNull(true) },
            .{ "HAS_WAITPID", .flagOrNull(true) },
            .{ "HAS_GETGROUPS", .flagOrNull(true) },
            .{ "HAS_SETGROUPS", .flagOrNull(true) },
            .{ "HAS_INITGROUPS", .flagOrNull(true) },
            .{ "HAS_TERMIOS", .flagOrNull(true) },
            .{ "HAS_SETITIMER", .flagOrNull(true) },
            .{ "HAS_GETHOSTNAME", .flagOrNull(true) },
            .{ "HAS_UNAME", .flagOrNull(true) },
            .{ "HAS_GETTIMEOFDAY", .flagOrNull(true) },
            .{ "HAS_MKTIME", .flagOrNull(true) },
            .{ "HAVE_GMTIME_R", .flagOrNull(true) },
            .{ "HAVE_LOCALTIME_R", .flagOrNull(true) },
            .{ "HAS_SETSID", .flagOrNull(true) },
            .{ "HAS_PUTENV", .flagOrNull(true) },
            .{ "HAS_SETENV_UNSETENV", .flagOrNull(true) },
            .{ "HAS_LOCALE_H", .flagOrNull(true) },
            .{ "HAS_XLOCALE_H", .flagOrNull(false) },
            .{ "HAS_STRTOD_L", .flagOrNull(has_strtod_l) },
            .{ "HAS_MMAP", .flagOrNull(true) },
            .{ "HAS_PWRITE", .flagOrNull(true) },
            .{ "HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC", .flagOrNull(has_stat_nsec) },
            .{ "HAVE_STRUCT_STAT_ST_ATIMESPEC_TV_NSEC", .flagOrNull(false) },
            .{ "HAVE_STRUCT_STAT_ST_ATIMENSEC", .flagOrNull(false) },
            .{ "HAS_GETHOSTBYNAME_R", .int(Config.config.gethostbyname_r_args) },
            .{ "HAS_GETHOSTBYADDR_R", .int(Config.config.gethostbyaddr_r_args) },
            .{ "HAS_MKSTEMP", .flagOrNull(true) },
            .{ "HAS_NICE", .flagOrNull(true) },
            .{ "HAS_DUP3", .flagOrNull(has_dup3) },
            .{ "HAS_PIPE2", .flagOrNull(has_pipe2) },
            .{ "HAS_ACCEPT4", .flagOrNull(has_accept4) },
            .{ "HAS_GETAUXVAL", .flagOrNull(has_getauxval) },
            .{ "HAS_SYS_SHM_H", .flagOrNull(true) },
            .{ "HAS_SHMAT", .flagOrNull(true) },
            .{ "HAS_EXECVPE", .flagOrNull(has_execvpe) },
            .{ "HAS_POSIX_SPAWN", .flagOrNull(has_posix_spawn) },
            // Do not opt into MAP_HUGETLB without a target probe.
            .{ "HAS_HUGE_PAGES", .flagOrNull(false) },
            .{ "HUGE_PAGE_SIZE", .flagOrNull(false) },
            .{ "HAS_LIBUNWIND", .flagOrNull(false) },
            .{ "HAS_BROKEN_PRINTF", .flagOrNull(false) },
            .{ "HAS_POSIX_MONOTONIC_CLOCK", .flagOrNull(has_posix_monotonic_clock) },
            .{ "HAS_CLOCK_GETTIME_NSEC_NP", .flagOrNull(false) },
            // Both bundled Linux C libraries provide pthread_getaffinity_np;
            // the GNU/BSD spelling switch is for other operating systems.
            .{ "HAS_GNU_GETAFFINITY_NP", .flagOrNull(has_gnu_getaffinity_np) },
            .{ "HAS_BSD_GETAFFINITY_NP", .flagOrNull(false) },
            // The build supplies a target-built static zstd library.
            .{ "HAS_ZSTD", .flagOrNull(true) },
            .{ "HAVE_MAX_ALIGN_T", .flagOrNull(true) },
            .{ "HAVE_GETGRNAM_R", .flagOrNull(true) },
            .{ "HAVE_GETGRGID_R", .flagOrNull(true) },
            .{ "HAVE_GETPWNAM_R", .flagOrNull(true) },
            .{ "HAVE_GETPWUID_R", .flagOrNull(true) },
            .{ "HAVE_GETLOGIN_R", .flagOrNull(true) },
            // Zig's clang frontend supports the labels-as-values extension.
            .{ "HAVE_LABELS_AS_VALUES", .flagOrNull(true) },
            .{ "HAVE___TSAN_FUNC_EXIT_VOID_VOID_P", .flagOrNull(false) },
            .{ "HAVE___TSAN_FUNC_EXIT_VOID_VOID", .flagOrNull(false) },
        },
    );
}

fn gnuLibCAtLeast(version: ?std.SemanticVersion, minimum: std.SemanticVersion) bool {
    const current = version orelse return false;
    return switch (current.order(minimum)) {
        .lt => false,
        .eq, .gt => true,
    };
}

fn libcHasFeature(
    is_musl: bool,
    glibc_version: ?std.SemanticVersion,
    minimum: std.SemanticVersion,
) bool {
    return is_musl or gnuLibCAtLeast(glibc_version, minimum);
}
