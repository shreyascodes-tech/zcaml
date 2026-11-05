//! Generates C configuration headers and OCaml configuration modules
//! (`config.ml`, `sys.ml`, `dynlink_config.ml`) that upstream `configure` would produce.
const std = @import("std");
const Source = @import("source.zig");
const Platform = @import("platform.zig");
const Var = Source.Var;

/// Where relocatable installs find the stdlib, relative to `bin/`.
pub const stdlib_dir_from_bin = "../lib/ocaml";

/// `runtime/caml/m.h`: machine description.
pub fn machineH(src: *const Source, p: Platform) []const u8 {
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
        .{ .name = "ARCH_ALIGN_INT64", .value = if (!p.arch64) "1" else null },
        .{ .name = "HEADER_RESERVED_BITS", .value = "0" },
        .{ .name = "ASM_CFI_SUPPORTED", .value = if (!p.is_windows) "1" else null },
        .{ .name = "ASM_SIZE_TYPE_DIRECTIVES", .value = if (p.is_elf) "1" else null },
        .{ .name = "WITH_FRAME_POINTERS", .value = null },
        .{ .name = "NO_NAKED_POINTERS", .value = "1" },
        .{ .name = "CAML_WITH_FPIC", .value = null },
        .{ .name = "CAML_SAFE_STRING", .value = "1" },
        .{ .name = "FLAT_FLOAT_ARRAY", .value = "1" },
        .{ .name = "FUNCTION_SECTIONS", .value = if (p.is_elf) "1" else null },
        .{ .name = "SUPPORTS_ALIGNED_ATTRIBUTE", .value = "1" },
        .{ .name = "SUPPORTS_TREE_VECTORIZE", .value = "1" },
        .{ .name = "USE_MMAP_MAP_STACK", .value = if (p.resolved.result.os.tag == .openbsd) "1" else null },
        .{ .name = "WITH_NONEXECSTACK_NOTE", .value = if (p.is_linux and p.is_elf) "1" else null },
    };
    return src.renderConfigHeader("runtime/caml/m.h.in", &entries, &.{}, "");
}

/// `runtime/caml/s.h`: OS / libc capabilities.
pub fn systemH(src: *const Source, p: Platform) []const u8 {
    const b = src.b;
    const is_unix = !p.is_windows;
    const entries = [_]Var{
        .{ .name = "OCAML_OS_TYPE", .value = b.fmt("\"{s}\"", .{p.osType()}) },
        .{ .name = "POSIX_SIGNALS", .value = if (is_unix) "1" else null },
        .{ .name = "BSD_SIGNALS", .value = if (is_unix) "1" else null },
        .{ .name = "SUPPORT_DYNAMIC_LINKING", .value = "1" },
        .{ .name = "HAS_FULL_THREAD_VARIABLES", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_C99_FLOAT_OPS", .value = "1" },
        .{ .name = "HAS_WORKING_FMA", .value = "1" },
        .{ .name = "HAS_WORKING_ROUND", .value = "1" },
        .{ .name = "HAS_GETENTROPY", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_GETRUSAGE", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_TIMES", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_STRLCPY", .value = if (p.is_macos or p.is_bsd) "1" else null },
        .{ .name = "HAS_SECURE_GETENV", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAS___SECURE_GETENV", .value = null },
        .{ .name = "HAS_ISSETUGID", .value = if (p.is_macos or p.is_bsd) "1" else null },
        .{ .name = "HAS_SYS_MMAN_H", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_LINUX_FUTEX_H", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAS_SOCKETS", .value = "1" },
        .{ .name = "HAS_SOCKETPAIR", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_AFUNIX_H", .value = if (p.is_windows) "1" else null },
        .{ .name = "HAS_INET_ATON", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_IPV6", .value = "1" },
        .{ .name = "HAS_PTHREAD_NP_H", .value = if (p.is_bsd) "1" else null },
        .{ .name = "HAS_PRCTL", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAVE_PTHREAD_CANCEL", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_PTHREAD_SETNAME_NP", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_PTHREAD_SET_NAME_NP", .value = null },
        .{ .name = "HAS_SETTHREADDESCRIPTION", .value = if (p.is_windows) "1" else null },
        .{ .name = "HAS_DECL_SETTHREADDESCRIPTION", .value = if (p.is_windows) "1" else null },
        .{ .name = "HAS_LIBGEN_H", .value = if (is_unix) "1" else null },
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
        .{ .name = "HAVE_GMTIME_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_LOCALTIME_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_SETSID", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_PUTENV", .value = "1" },
        .{ .name = "HAS_SETENV_UNSETENV", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_LOCALE_H", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_XLOCALE_H", .value = if (p.is_macos) "1" else null },
        .{ .name = "HAS_STRTOD_L", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_MMAP", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_PWRITE", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAVE_STRUCT_STAT_ST_ATIMESPEC_TV_NSEC", .value = if (p.is_macos or p.is_bsd) "1" else null },
        .{ .name = "HAVE_STRUCT_STAT_ST_ATIMENSEC", .value = null },
        .{ .name = "HAS_GETHOSTBYNAME_R", .value = if (p.is_linux) "6" else null },
        .{ .name = "HAS_GETHOSTBYADDR_R", .value = if (p.is_linux) "8" else null },
        .{ .name = "HAS_MKSTEMP", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_NICE", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_DUP3", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_PIPE2", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_ACCEPT4", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_GETAUXVAL", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAS_SYS_SHM_H", .value = if (p.is_linux or p.is_macos) "1" else null },
        .{ .name = "HAS_SHMAT", .value = if (p.is_linux or p.is_macos) "1" else null },
        .{ .name = "HAS_EXECVPE", .value = if (p.is_linux or p.is_windows) "1" else null },
        .{ .name = "HAS_POSIX_SPAWN", .value = if (is_unix) "1" else null },
        .{ .name = "HAS_HUGE_PAGES", .value = null },
        .{ .name = "HUGE_PAGE_SIZE", .value = null },
        .{ .name = "HAS_LIBUNWIND", .value = null },
        .{ .name = "HAS_BROKEN_PRINTF", .value = if (p.is_windows) "1" else null },
        .{ .name = "HAS_POSIX_MONOTONIC_CLOCK", .value = if (p.is_linux or p.is_bsd) "1" else null },
        .{ .name = "HAS_CLOCK_GETTIME_NSEC_NP", .value = if (p.is_macos) "1" else null },
        .{ .name = "HAS_GNU_GETAFFINITY_NP", .value = if (p.is_linux) "1" else null },
        .{ .name = "HAS_BSD_GETAFFINITY_NP", .value = null },
        .{ .name = "HAS_ZSTD", .value = "1" },
        .{ .name = "HAVE_MAX_ALIGN_T", .value = "1" },
        .{ .name = "HAVE_GETGRNAM_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_GETGRGID_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_GETPWNAM_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_GETPWUID_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_GETLOGIN_R", .value = if (is_unix) "1" else null },
        .{ .name = "HAVE_LABELS_AS_VALUES", .value = "1" },
        .{ .name = "HAVE___TSAN_FUNC_EXIT_VOID_VOID_P", .value = null },
        .{ .name = "HAVE___TSAN_FUNC_EXIT_VOID_VOID", .value = null },
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
pub fn versionH(src: *const Source) []const u8 {
    const b = src.b;
    const v = src.manifest.version;
    return src.renderConfigHeader("runtime/caml/version.h.in", &.{
        .{ .name = "OCAML_VERSION_MAJOR", .value = b.fmt("{d}", .{v.major}) },
        .{ .name = "OCAML_VERSION_MINOR", .value = b.fmt("{d}", .{v.minor}) },
        .{ .name = "OCAML_VERSION_PATCHLEVEL", .value = b.fmt("{d}", .{v.patchlevel}) },
        .{ .name = "OCAML_VERSION_ADDITIONAL", .value = if (v.extra.len > 0) b.fmt("\"{s}\"", .{v.extra}) else null },
        .{ .name = "OCAML_VERSION_EXTRA", .value = if (v.extra.len > 0) b.fmt("\"{s}{s}\"", .{ v.extra_prefix, v.extra }) else null },
        .{ .name = "OCAML_VERSION", .value = b.fmt("{d}", .{v.number}) },
        .{ .name = "OCAML_VERSION_STRING", .value = b.fmt("\"{s}\"", .{v.string}) },
        .{ .name = "OCAML_RELEASE_NUMBER", .value = b.fmt("{d}", .{v.release_number}) },
    }, &.{}, "");
}

/// `runtime/caml/exec.h`
pub fn execH(src: *const Source) []const u8 {
    const b = src.b;
    const magic = src.manifest.version.magic;
    return src.renderConfigHeader("runtime/caml/exec.h.in", &.{
        .{ .name = "EXEC_MAGIC_LENGTH", .value = b.fmt("{d}", .{magic.exec_length}) },
        .{ .name = "MAGIC_NUMBER_PREFIX", .value = b.fmt("\"{s}\"", .{magic.prefix}) },
        .{ .name = "EXEC_FORMAT", .value = b.fmt("\"{s}\"", .{magic.exec_format}) },
        .{ .name = "MAGIC_NUMBER_VERSION", .value = b.fmt("\"{s}\"", .{magic.version}) },
    }, &.{ "CAML_EXEC_H", "TRAILER_SIZE", "EXEC_MAGIC" }, "");
}

/// `runtime/build_config.h`
pub fn buildConfigH(src: *const Source, p: Platform) []const u8 {
    const b = src.b;
    const stdlib_literal = if (p.is_windows)
        b.fmt("L\"{s}\"", .{stdlib_dir_from_bin})
    else
        b.fmt("\"{s}\"", .{stdlib_dir_from_bin});

    return b.fmt(
        \\/* Generated by zcaml */
        \\#define OCAML_STDLIB_DIR {s}
        \\#define HOST "{s}"
        \\#define BYTECODE_RUNTIME_ID "{s}"
        \\
    , .{ stdlib_literal, p.triplet, p.runtimeId(b, src.manifest.version) });
}

pub fn compilerConfigCommon(src: *const Source) []const u8 {
    const mn = src.manifest.version.magic.numbers;
    return src.renderAt("utils/config.common.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from utils/config.common.ml.in" },
        .{ .name = "EXEC_MAGIC_NUMBER", .value = mn.exec },
        .{ .name = "CMI_MAGIC_NUMBER", .value = mn.cmi },
        .{ .name = "CMO_MAGIC_NUMBER", .value = mn.cmo },
        .{ .name = "CMA_MAGIC_NUMBER", .value = mn.cma },
        .{ .name = "CMX_MAGIC_NUMBER", .value = mn.cmx_clambda },
        .{ .name = "CMXA_MAGIC_NUMBER", .value = mn.cmxa_clambda },
        .{ .name = "AST_IMPL_MAGIC_NUMBER", .value = mn.ast_impl },
        .{ .name = "AST_INTF_MAGIC_NUMBER", .value = mn.ast_intf },
        .{ .name = "CMXS_MAGIC_NUMBER", .value = mn.cmxs },
        .{ .name = "CMT_MAGIC_NUMBER", .value = mn.cmt },
        .{ .name = "LINEAR_MAGIC_NUMBER", .value = mn.linear },
    });
}

/// `utils/config.ml`: `Config` as `configure` would produce it for `host` -> `target`,
/// followed by `config_common` (see `compilerConfigCommon`).
pub fn compilerConfigMl(src: *const Source, config_common: []const u8, host: Platform, target: Platform) []const u8 {
    const b = src.b;
    const c = target.c;

    const cflags = std.mem.join(b.allocator, " ", c.cflags) catch @panic("OOM");
    const cppflags = std.mem.join(b.allocator, " ", c.cppflags) catch @panic("OOM");
    var cclibs: std.ArrayList(u8) = .empty;
    for (c.libs, 0..) |l, i| {
        cclibs.print(b.allocator, "{s}-l{s}", .{ if (i > 0) " " else "", l }) catch @panic("OOM");
    }
    const rpath = if (target.is_elf) "-Wl,-rpath," else "";
    // Zig on PATH keeps installed compilers relocatable, without system cross-gcc.
    const triple = target.resolved.result.zigTriple(b.allocator) catch @panic("OOM");
    const cc = b.fmt("zig cc -target {s} -fno-sanitize=undefined{s}", .{ triple, if (target.resolved.result.abi.isMusl()) " -dynamic" else "" });
    const asm_cmd = b.fmt("{s}{s} -Wno-trigraphs -fdebug-compilation-dir=. -c", .{ cc, if (target.arch == .riscv) " -mcpu=baseline_rv64-c-zca-zcd" else "" });
    const packld = b.fmt("{s} -nostdlib -r -o ", .{cc});
    const flexlink_flags = if (target.is_windows) std.mem.join(b.allocator, " ", target.flexlinkFlags(b)) catch @panic("OOM") else "";
    const mkdll = if (target.is_windows)
        b.fmt("flexlink {s}", .{flexlink_flags})
    else
        b.fmt("{s} -shared{s}", .{ cc, if (target.is_macos) " -undefined dynamic_lookup -Wl,-w" else "" });
    const mkmaindll = if (target.is_windows) b.fmt("flexlink -maindll {s}", .{flexlink_flags}) else mkdll;
    const mkexe = if (target.is_windows)
        b.fmt("flexlink -exe {s} -link -municode", .{flexlink_flags})
    else
        b.fmt("{s} {s}{s}", .{ cc, cflags, if (target.is_elf) " -Wl,-E" else "" });

    const runtime_id = target.runtimeId(b, src.manifest.version);
    const generated = src.renderAt("utils/config.generated.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from utils/config.generated.ml.in" },
        .{ .name = "QS", .value = "" },
        // Relocatable releases resolve these at runtime: `bindir` from the relative
        // stdlib, `target_bindir = "."` as the directory of the running compiler.
        .{ .name = "ocaml_bindir", .value = "." },
        .{ .name = "TARGET_BINDIR", .value = "." },
        .{ .name = "ccomp_type", .value = "cc" },
        .{ .name = "CC", .value = cc },
        .{ .name = "ocaml_cc_vendor", .value = "clang-19" },
        .{ .name = "outputobj", .value = "-o " },
        .{ .name = "cc_has_debug_prefix_map", .value = "true" },
        .{ .name = "ocaml_cv_prog_as_debug_prefix_map", .value = "false" },
        .{ .name = "as_is_cc", .value = "true" },
        .{ .name = "bytecode_cflags", .value = cflags },
        .{ .name = "bytecode_cppflags", .value = cppflags },
        .{ .name = "native_cflags", .value = cflags },
        .{ .name = "native_cppflags", .value = cppflags },
        .{ .name = "zstd_libs", .value = "-lzstd" },
        .{ .name = "cclibs", .value = cclibs.items },
        .{ .name = "native_ldflags", .value = "" },
        .{ .name = "with_nonexecstack_note", .value = boolStr(target.is_linux and target.is_elf) },
        .{ .name = "PACKLD", .value = packld },
        .{ .name = "rpath", .value = rpath },
        .{ .name = "mksharedlibrpath", .value = rpath },
        .{ .name = "AR", .value = "zig ar" },
        .{ .name = "supports_shared_libraries", .value = "true" },
        .{ .name = "natdynlink", .value = boolStr(target.hasNativeCompiler()) },
        .{ .name = "mkdll_exp", .value = mkdll },
        .{ .name = "mkexe_exp", .value = mkexe },
        .{ .name = "mkmaindll_exp", .value = mkmaindll },
        .{ .name = "flambda", .value = "false" },
        .{ .name = "flambda_invariants", .value = "false" },
        .{ .name = "cmm_invariants", .value = "false" },
        .{ .name = "codegen_invariants", .value = "false" },
        .{ .name = "windows_unicode", .value = if (target.is_windows) "1" else "0" },
        .{ .name = "flat_float_array", .value = "true" },
        .{ .name = "align_double", .value = boolStr(!target.arch64) },
        .{ .name = "align_int64", .value = boolStr(!target.arch64) },
        .{ .name = "function_sections", .value = boolStr(target.is_elf) },
        .{ .name = "afl", .value = "false" },
        .{ .name = "bytecode_runtime_id", .value = runtime_id },
        .{ .name = "native_runtime_id", .value = runtime_id },
        .{ .name = "native_compiler", .value = boolStr(target.hasNativeCompiler()) },
        .{ .name = "arch", .value = target.archName() },
        .{ .name = "model", .value = target.model },
        .{ .name = "system", .value = target.system },
        .{ .name = "target_os_type", .value = target.osType() },
        .{ .name = "AS", .value = asm_cmd },
        .{ .name = "asm_cfi_supported", .value = boolStr(!target.is_windows) },
        .{ .name = "asm_size_type_directives", .value = boolStr(target.is_elf) },
        .{ .name = "asm_dwarf_version", .value = "None" },
        .{ .name = "frame_pointers", .value = "false" },
        .{ .name = "reserved_header_bits", .value = "0" },
        .{ .name = "EXEEXT", .value = target.exeExt() },
        .{ .name = "OBJEXT", .value = "o" },
        .{ .name = "S", .value = "s" },
        .{ .name = "libext", .value = "a" },
        .{ .name = "SO", .value = target.dllExt() },
        .{ .name = "host", .value = host.triplet },
        .{ .name = "target", .value = target.triplet },
        .{ .name = "systhread_support", .value = "true" },
        .{ .name = "flexdll_dir", .value = if (target.is_windows) "\"+flexdll\"" else "" },
        .{ .name = "ar_supports_response_files", .value = "true" },
        .{ .name = "tsan", .value = "false" },
        .{ .name = "shebangscripts", .value = boolStr(!host.is_windows) },
        .{ .name = "suffixing", .value = "false" },
        .{ .name = "launch_method_target", .value = if (target.is_windows) "exe" else "sh" },
        .{ .name = "runtime_search_target", .value = "fallback" },
    });
    return b.fmt("{s}\n{s}", .{ generated, config_common });
}

pub fn stdlibSysMl(src: *const Source) []const u8 {
    const b = src.b;
    const v = src.manifest.version;
    const release_extra = if (v.extra.len == 0)
        "None"
    else
        b.fmt("Some ({s}, \"{s}\")", .{ if (std.mem.eql(u8, v.extra_prefix, "~")) "Tilde" else "Plus", v.extra });

    return src.renderAt("stdlib/sys.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml from stdlib/sys.ml.in" },
        .{ .name = "VERSION", .value = v.string },
        .{ .name = "OCAML_DEVELOPMENT_VERSION", .value = if (v.dev) "true" else "false" },
        .{ .name = "OCAML_VERSION_MAJOR", .value = b.fmt("{d}", .{v.major}) },
        .{ .name = "OCAML_VERSION_MINOR", .value = b.fmt("{d}", .{v.minor}) },
        .{ .name = "OCAML_VERSION_PATCHLEVEL", .value = b.fmt("{d}", .{v.patchlevel}) },
        .{ .name = "OCAML_RELEASE_EXTRA", .value = release_extra },
    });
}

pub fn dynlinkConfigMl(src: *const Source, p: Platform) []const u8 {
    const b = src.b;
    const m = src.manifest;
    const magic = m.version.magic;
    return src.renderAt("otherlibs/dynlink/dynlink_config.ml.in", &.{
        .{ .name = "configure_input", .value = "Generated by zcaml" },
        .{ .name = "MAGIC_LENGTH", .value = b.fmt("{d}", .{magic.exec_length}) },
        .{ .name = "QS", .value = "" },
        .{ .name = "SO", .value = p.dllExt() },
        .{ .name = "CMO_MAGIC_NUMBER", .value = magic.numbers.cmo },
        .{ .name = "CMA_MAGIC_NUMBER", .value = magic.numbers.cma },
        .{ .name = "CMXS_MAGIC_NUMBER", .value = magic.numbers.cmxs },
        .{ .name = "bytecode_runtime_id", .value = p.runtimeId(b, m.version) },
        .{ .name = "target", .value = p.triplet },
    });
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}
