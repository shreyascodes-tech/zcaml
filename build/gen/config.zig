//! The values OCaml's `./configure` would substitute into the `*.in`
//! templates: one struct per template, one field per variable.

const std = @import("std");
const Writer = std.Io.Writer;

const Target = @import("Target");
const Version = @import("Version.zig");
const template = @import("template.zig");
const Quoted = template.Quoted;
const Join = template.Join;
const Qs = template.Qs;

pub const Tools = struct {
    cc: []const u8,
    ar: []const u8,
    asm_: ?[]const u8 = null,
    /// Default: `<cc> -r -o ` (configure finds the system `ld`, which is
    /// wrong when cross-compiling).
    packld: ?[]const u8 = null,
    cc_vendor: []const u8 = default_cc_vendor,

    /// Matches the clang bundled with zig 0.16.
    pub const default_cc_vendor = "clang-21-1";
};

pub const Layout = union(enum) {
    absolute: struct { bindir: []const u8, libdir: []const u8 },
    /// `--with-relative-libdir`: relocatable.
    relative: struct { bindir_to_libdir: []const u8 = "../lib/ocaml" },
};

/// Must agree between `m.h`, `config.ml` and the runtime ID in
/// `build_config.h`, so everything reads them from here.
pub const Features = struct {
    flat_float_array: bool = true,
    frame_pointers: bool = false,
    reserved_header_bits: u8 = 0,
    tsan: bool = false,
    /// Linker flags for compressed marshalling; `null` disables `HAS_ZSTD`.
    zstd_libs: ?[]const u8 = null,

    pub fn zstd(f: Features) bool {
        return f.zstd_libs != null;
    }
};

pub const Options = struct {
    version: Version,
    host: *const Target,
    /// Everything except `Config.host` comes from the target.
    target: *const Target,
    tools: Tools,
    layout: Layout,
    features: Features = .{},
    /// configure enables this by default; it only slows down a shipped compiler.
    codegen_invariants: bool = false,
};

pub const MH = struct {
    ARCH_SIXTYFOUR: bool,
    ARCH_BIG_ENDIAN: bool,
    ARCH_ALIGN_DOUBLE: bool,
    HAS_ARCH_CODE32: bool,
    SIZEOF_INT: u16,
    SIZEOF_LONG: u16,
    SIZEOF_PTR: u16,
    SIZEOF_SHORT: u16,
    SIZEOF_LONGLONG: u16,
    ARCH_ALIGN_INT64: bool,
    HEADER_RESERVED_BITS: u8,
    ASM_CFI_SUPPORTED: bool,
    ASM_SIZE_TYPE_DIRECTIVES: bool,
    WITH_FRAME_POINTERS: bool,
    CAML_WITH_FPIC: bool,
    FLAT_FLOAT_ARRAY: bool,
    FUNCTION_SECTIONS: bool,
    SUPPORTS_ALIGNED_ATTRIBUTE: bool,
    SUPPORTS_TREE_VECTORIZE: bool,
    USE_MMAP_MAP_STACK: bool,
    WITH_NONEXECSTACK_NOTE: bool,

    pub fn init(o: Options) MH {
        const t = o.target;
        return .{
            .ARCH_SIXTYFOUR = t.is64(),
            .ARCH_BIG_ENDIAN = t.zig.cpu.arch.endian() == .big,
            .ARCH_ALIGN_DOUBLE = t.alignDouble(),
            .HAS_ARCH_CODE32 = t.is64() and t.archCode32(),
            .SIZEOF_INT = t.zig.cTypeByteSize(.int),
            .SIZEOF_LONG = t.zig.cTypeByteSize(.long),
            .SIZEOF_PTR = t.ptrSize(),
            .SIZEOF_SHORT = t.zig.cTypeByteSize(.short),
            .SIZEOF_LONGLONG = t.zig.cTypeByteSize(.longlong),
            .ARCH_ALIGN_INT64 = t.alignInt64(),
            .HEADER_RESERVED_BITS = o.features.reserved_header_bits,
            .ASM_CFI_SUPPORTED = t.asmCfiSupported(),
            .ASM_SIZE_TYPE_DIRECTIVES = t.asmSizeTypeDirectives(),
            .WITH_FRAME_POINTERS = o.features.frame_pointers,
            .CAML_WITH_FPIC = false,
            .FLAT_FLOAT_ARRAY = o.features.flat_float_array,
            .FUNCTION_SECTIONS = t.functionSections(),
            .SUPPORTS_ALIGNED_ATTRIBUTE = false,
            // gcc-only `__attribute__((optimize("tree-vectorize")))`.
            .SUPPORTS_TREE_VECTORIZE = false,
            .USE_MMAP_MAP_STACK = false,
            .WITH_NONEXECSTACK_NOTE = t.nonexecstackNote(),
        };
    }
};

pub const SH = struct {
    OCAML_OS_TYPE: Quoted([]const u8),
    POSIX_SIGNALS: bool,
    BSD_SIGNALS: bool,
    SUPPORT_DYNAMIC_LINKING: bool,
    HAS_FULL_THREAD_VARIABLES: bool,
    HAS_C99_FLOAT_OPS: bool,
    HAS_WORKING_FMA: bool,
    HAS_WORKING_ROUND: bool,
    HAS_GETENTROPY: bool,
    HAS_GETRUSAGE: bool,
    HAS_TIMES: bool,
    HAS_STRLCPY: bool,
    HAS_SECURE_GETENV: bool,
    HAS___SECURE_GETENV: bool,
    HAS_ISSETUGID: bool,
    HAS_SYS_MMAN_H: bool,
    HAS_LINUX_FUTEX_H: bool,
    HAS_SOCKETS: bool,
    HAS_SOCKETPAIR: bool,
    HAS_AFUNIX_H: bool,
    HAS_INET_ATON: bool,
    HAS_IPV6: bool,
    HAS_PTHREAD_NP_H: bool,
    HAS_PRCTL: bool,
    HAVE_PTHREAD_CANCEL: bool,
    HAVE_PTHREAD_SETNAME_NP: bool,
    HAVE_PTHREAD_SET_NAME_NP: bool,
    HAS_SETTHREADDESCRIPTION: bool,
    HAS_DECL_SETTHREADDESCRIPTION: bool,
    HAS_LIBGEN_H: bool,
    HAS_DIRENT: bool,
    HAS_REWINDDIR: bool,
    HAS_LOCKF: bool,
    HAS_MKFIFO: bool,
    HAS_GETCWD: bool,
    HAS_SYSTEM: bool,
    HAS_UTIME: bool,
    HAS_UTIMES: bool,
    HAS_FCHMOD: bool,
    HAS_TRUNCATE: bool,
    HAS_SELECT: bool,
    HAS_SYS_SELECT_H: bool,
    HAS_NANOSLEEP: bool,
    HAS_SYMLINK: bool,
    HAS_REALPATH: bool,
    HAS_WAIT4: bool,
    HAS_WAITPID: bool,
    HAS_GETGROUPS: bool,
    HAS_SETGROUPS: bool,
    HAS_INITGROUPS: bool,
    HAS_TERMIOS: bool,
    HAS_SETITIMER: bool,
    HAS_GETHOSTNAME: bool,
    HAS_UNAME: bool,
    HAS_GETTIMEOFDAY: bool,
    HAS_MKTIME: bool,
    HAVE_GMTIME_R: bool,
    HAVE_LOCALTIME_R: bool,
    HAS_SETSID: bool,
    HAS_PUTENV: bool,
    HAS_SETENV_UNSETENV: bool,
    HAS_LOCALE_H: bool,
    HAS_XLOCALE_H: bool,
    HAS_STRTOD_L: bool,
    HAS_MMAP: bool,
    HAS_PWRITE: bool,
    HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC: bool,
    HAVE_STRUCT_STAT_ST_ATIMESPEC_TV_NSEC: bool,
    HAVE_STRUCT_STAT_ST_ATIMENSEC: bool,
    HAS_GETHOSTBYNAME_R: ?u8,
    HAS_GETHOSTBYADDR_R: ?u8,
    HAS_MKSTEMP: bool,
    HAS_NICE: bool,
    HAS_DUP3: bool,
    HAS_PIPE2: bool,
    HAS_ACCEPT4: bool,
    HAS_GETAUXVAL: bool,
    HAS_SYS_SHM_H: bool,
    HAS_SHMAT: bool,
    HAS_EXECVPE: bool,
    HAS_POSIX_SPAWN: bool,
    HAS_HUGE_PAGES: bool,
    HUGE_PAGE_SIZE: ?[]const u8,
    HAS_LIBUNWIND: bool,
    HAS_BROKEN_PRINTF: bool,
    HAS_POSIX_MONOTONIC_CLOCK: bool,
    HAS_CLOCK_GETTIME_NSEC_NP: bool,
    HAS_GNU_GETAFFINITY_NP: bool,
    HAS_BSD_GETAFFINITY_NP: bool,
    HAS_ZSTD: bool,
    HAVE_MAX_ALIGN_T: bool,
    HAVE_GETGRNAM_R: bool,
    HAVE_GETGRGID_R: bool,
    HAVE_GETPWNAM_R: bool,
    HAVE_GETPWUID_R: bool,
    HAVE_GETLOGIN_R: bool,
    HAVE_LABELS_AS_VALUES: bool,
    HAVE___TSAN_FUNC_EXIT_VOID_VOID_P: bool,
    HAVE___TSAN_FUNC_EXIT_VOID_VOID: bool,

    /// With zig's bundled libcs the answers are fixed per libc family.
    pub fn init(o: Options) SH {
        const t = o.target;
        const darwin = t.libc == .darwin;
        const freebsd = t.libc == .freebsd;
        const linux = t.zig.os.tag == .linux;
        const bsd_like = darwin or freebsd;
        return .{
            .OCAML_OS_TYPE = .{ .v = Target.os_type },
            .POSIX_SIGNALS = true,
            .BSD_SIGNALS = false,
            .SUPPORT_DYNAMIC_LINKING = Target.supports_shared_libraries,
            // macOS and MinGW-w64 have problems with TLS accessed from DLLs.
            .HAS_FULL_THREAD_VARIABLES = !darwin,
            .HAS_C99_FLOAT_OPS = true,
            .HAS_WORKING_FMA = true,
            .HAS_WORKING_ROUND = true,
            .HAS_GETENTROPY = true,
            .HAS_GETRUSAGE = true,
            .HAS_TIMES = true,
            .HAS_STRLCPY = switch (t.libc) {
                .glibc => |v| v.order(.{ .major = 2, .minor = 38, .patch = 0 }) != .lt,
                .musl, .darwin, .freebsd => true,
            },
            .HAS_SECURE_GETENV = !darwin,
            .HAS___SECURE_GETENV = false,
            .HAS_ISSETUGID = t.libc != .glibc,
            .HAS_SYS_MMAN_H = true,
            .HAS_LINUX_FUTEX_H = linux,
            .HAS_SOCKETS = true,
            .HAS_SOCKETPAIR = false,
            .HAS_AFUNIX_H = false,
            .HAS_INET_ATON = true,
            .HAS_IPV6 = true,
            .HAS_PTHREAD_NP_H = freebsd,
            .HAS_PRCTL = linux,
            .HAVE_PTHREAD_CANCEL = true,
            .HAVE_PTHREAD_SETNAME_NP = true,
            .HAVE_PTHREAD_SET_NAME_NP = false,
            .HAS_SETTHREADDESCRIPTION = false,
            .HAS_DECL_SETTHREADDESCRIPTION = false,
            .HAS_LIBGEN_H = true,
            .HAS_DIRENT = true,
            .HAS_REWINDDIR = true,
            .HAS_LOCKF = true,
            .HAS_MKFIFO = true,
            .HAS_GETCWD = true,
            .HAS_SYSTEM = true,
            .HAS_UTIME = true,
            .HAS_UTIMES = true,
            .HAS_FCHMOD = true,
            .HAS_TRUNCATE = true,
            .HAS_SELECT = true,
            .HAS_SYS_SELECT_H = true,
            .HAS_NANOSLEEP = true,
            .HAS_SYMLINK = true,
            .HAS_REALPATH = true,
            .HAS_WAIT4 = true,
            .HAS_WAITPID = true,
            .HAS_GETGROUPS = true,
            .HAS_SETGROUPS = true,
            .HAS_INITGROUPS = true,
            .HAS_TERMIOS = true,
            .HAS_SETITIMER = true,
            .HAS_GETHOSTNAME = true,
            .HAS_UNAME = true,
            .HAS_GETTIMEOFDAY = true,
            .HAS_MKTIME = true,
            .HAVE_GMTIME_R = true,
            .HAVE_LOCALTIME_R = true,
            .HAS_SETSID = true,
            .HAS_PUTENV = true,
            .HAS_SETENV_UNSETENV = true,
            .HAS_LOCALE_H = true,
            .HAS_XLOCALE_H = bsd_like,
            .HAS_STRTOD_L = true,
            .HAS_MMAP = true,
            .HAS_PWRITE = true,
            .HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC = !darwin,
            .HAVE_STRUCT_STAT_ST_ATIMESPEC_TV_NSEC = bsd_like,
            .HAVE_STRUCT_STAT_ST_ATIMENSEC = freebsd,
            .HAS_GETHOSTBYNAME_R = if (darwin) null else 6,
            .HAS_GETHOSTBYADDR_R = if (darwin) null else 8,
            .HAS_MKSTEMP = true,
            .HAS_NICE = true,
            .HAS_DUP3 = !darwin,
            .HAS_PIPE2 = !darwin,
            .HAS_ACCEPT4 = !darwin,
            .HAS_GETAUXVAL = linux,
            .HAS_SYS_SHM_H = true,
            .HAS_SHMAT = true,
            .HAS_EXECVPE = linux,
            .HAS_POSIX_SPAWN = true,
            // configure runs a test program for this, so its answer depends on
            // the build machine; the fixtures were generated with it forced on.
            .HAS_HUGE_PAGES = linux,
            .HUGE_PAGE_SIZE = if (linux) "(4 * 1024 * 1024)" else null,
            .HAS_LIBUNWIND = false,
            .HAS_BROKEN_PRINTF = false,
            .HAS_POSIX_MONOTONIC_CLOCK = !darwin,
            .HAS_CLOCK_GETTIME_NSEC_NP = darwin,
            .HAS_GNU_GETAFFINITY_NP = !darwin,
            .HAS_BSD_GETAFFINITY_NP = false,
            .HAS_ZSTD = o.features.zstd(),
            .HAVE_MAX_ALIGN_T = true,
            .HAVE_GETGRNAM_R = true,
            .HAVE_GETGRGID_R = true,
            .HAVE_GETPWNAM_R = true,
            .HAVE_GETPWUID_R = true,
            .HAVE_GETLOGIN_R = true,
            .HAVE_LABELS_AS_VALUES = true,
            .HAVE___TSAN_FUNC_EXIT_VOID_VOID_P = false,
            .HAVE___TSAN_FUNC_EXIT_VOID_VOID = false,
        };
    }
};

pub const VersionH = struct {
    OCAML_VERSION_MAJOR: u32,
    OCAML_VERSION_MINOR: u32,
    OCAML_VERSION_PATCHLEVEL: u32,
    OCAML_VERSION_ADDITIONAL: Quoted([]const u8),
    OCAML_VERSION_EXTRA: Quoted([]const u8),
    OCAML_VERSION: u32,
    OCAML_VERSION_STRING: Quoted(Version),
    OCAML_RELEASE_NUMBER: u32,

    pub fn init(o: Options) VersionH {
        const v = o.version;
        return .{
            .OCAML_VERSION_MAJOR = v.major,
            .OCAML_VERSION_MINOR = v.minor,
            .OCAML_VERSION_PATCHLEVEL = v.patchlevel,
            // configure.ac means to define these only for versions with an
            // "extra" part, but its `m4_if` is buggy and always defines them.
            .OCAML_VERSION_ADDITIONAL = .{ .v = v.extra },
            .OCAML_VERSION_EXTRA = .{ .v = v.extra },
            .OCAML_VERSION = v.number(),
            .OCAML_VERSION_STRING = .{ .v = v },
            .OCAML_RELEASE_NUMBER = v.release_number,
        };
    }
};

pub const ExecH = struct {
    EXEC_MAGIC_LENGTH: usize,
    MAGIC_NUMBER_PREFIX: Quoted([]const u8),
    EXEC_FORMAT: Quoted([]const u8),
    MAGIC_NUMBER_VERSION: Quoted([]const u8),

    pub fn init(o: Options) ExecH {
        const v = o.version;
        return .{
            .EXEC_MAGIC_LENGTH = v.magicLength(),
            .MAGIC_NUMBER_PREFIX = .{ .v = v.magic_prefix },
            .EXEC_FORMAT = .{ .v = &.{@intFromEnum(Version.MagicKind.exec)} },
            .MAGIC_NUMBER_VERSION = .{ .v = v.magic_version },
        };
    }
};

/// Every `@VAR@` in `utils/config.{generated,common}.ml.in`,
/// `stdlib/sys.ml.in` and `otherlibs/dynlink/dynlink_config.ml.in`.
pub const Substs = struct {
    VERSION: Version,
    OCAML_DEVELOPMENT_VERSION: bool,
    OCAML_VERSION_MAJOR: u32,
    OCAML_VERSION_MINOR: u32,
    OCAML_VERSION_PATCHLEVEL: u32,
    OCAML_RELEASE_EXTRA: Version.ReleaseExtra,
    MAGIC_LENGTH: usize,
    EXEC_MAGIC_NUMBER: Version.Magic,
    CMI_MAGIC_NUMBER: Version.Magic,
    CMO_MAGIC_NUMBER: Version.Magic,
    CMA_MAGIC_NUMBER: Version.Magic,
    CMX_MAGIC_NUMBER: Version.Magic,
    CMXA_MAGIC_NUMBER: Version.Magic,
    AST_IMPL_MAGIC_NUMBER: Version.Magic,
    AST_INTF_MAGIC_NUMBER: Version.Magic,
    CMXS_MAGIC_NUMBER: Version.Magic,
    CMT_MAGIC_NUMBER: Version.Magic,
    LINEAR_MAGIC_NUMBER: Version.Magic,

    ocaml_bindir: []const u8,
    TARGET_BINDIR: []const u8,

    ccomp_type: []const u8,
    CC: []const u8,
    ocaml_cc_vendor: []const u8,
    outputobj: []const u8,
    cc_has_debug_prefix_map: bool,
    ocaml_cv_prog_as_debug_prefix_map: bool,
    as_is_cc: bool,
    bytecode_cflags: CFlags,
    bytecode_cppflags: []const u8,
    native_cflags: CFlags,
    native_cppflags: []const u8,
    zstd_libs: []const u8,
    cclibs: []const u8,
    native_ldflags: []const u8,
    with_nonexecstack_note: bool,
    PACKLD: Join(2),
    rpath: []const u8,
    mksharedlibrpath: []const u8,
    AR: []const u8,
    supports_shared_libraries: bool,
    natdynlink: bool,
    mkdll_exp: Join(2),
    mkexe_exp: Join(2),
    mkmaindll_exp: Join(2),

    flambda: bool,
    flambda_invariants: bool,
    cmm_invariants: bool,
    codegen_invariants: bool,
    windows_unicode: u8,
    flat_float_array: bool,
    align_double: bool,
    align_int64: bool,
    function_sections: bool,
    afl: bool,
    bytecode_runtime_id: [4]u8,
    native_runtime_id: [4]u8,
    native_compiler: bool,
    arch: []const u8,
    model: []const u8,
    system: []const u8,
    target_os_type: []const u8,
    AS: Join(2),
    asm_cfi_supported: bool,
    asm_size_type_directives: bool,
    /// Matches the clang bundled with zig 0.16.
    asm_dwarf_version: []const u8,
    frame_pointers: bool,
    reserved_header_bits: u8,
    EXEEXT: []const u8,
    OBJEXT: []const u8,
    S: []const u8,
    libext: []const u8,
    SO: []const u8,
    host: []const u8,
    target: []const u8,
    systhread_support: bool,
    flexdll_dir: []const u8,
    ar_supports_response_files: bool,
    tsan: bool,
    shebangscripts: bool,
    suffixing: bool,
    launch_method_target: []const u8,
    runtime_search_target: []const u8,

    QS: Qs,

    pub const Error = error{ValueTooLong};

    pub fn init(o: Options) Error!Substs {
        const t = o.target;
        const v = o.version;
        const e = t.ext();
        const ids = runtimeIds(o);
        const tools = o.tools;
        const darwin = t.isDarwin();
        const cflags_ = cflags(t);
        const cppflags = "-D_FILE_OFFSET_BITS=64";

        var s: Substs = .{
            .VERSION = v,
            .OCAML_DEVELOPMENT_VERSION = v.development,
            .OCAML_VERSION_MAJOR = v.major,
            .OCAML_VERSION_MINOR = v.minor,
            .OCAML_VERSION_PATCHLEVEL = v.patchlevel,
            .OCAML_RELEASE_EXTRA = v.releaseExtra(),
            .MAGIC_LENGTH = v.magicLength(),
            .EXEC_MAGIC_NUMBER = v.magic(.exec),
            .CMI_MAGIC_NUMBER = v.magic(.cmi),
            .CMO_MAGIC_NUMBER = v.magic(.cmo),
            .CMA_MAGIC_NUMBER = v.magic(.cma),
            .CMX_MAGIC_NUMBER = v.magic(.cmx_clambda),
            .CMXA_MAGIC_NUMBER = v.magic(.cmxa_clambda),
            .AST_IMPL_MAGIC_NUMBER = v.magic(.ast_impl),
            .AST_INTF_MAGIC_NUMBER = v.magic(.ast_intf),
            .CMXS_MAGIC_NUMBER = v.magic(.cmxs),
            .CMT_MAGIC_NUMBER = v.magic(.cmt),
            .LINEAR_MAGIC_NUMBER = v.magic(.linear),

            .ocaml_bindir = switch (o.layout) {
                .absolute => |a| a.bindir,
                .relative => "",
            },
            .TARGET_BINDIR = switch (o.layout) {
                .absolute => |a| a.bindir,
                .relative => ".",
            },

            .ccomp_type = "cc",
            .CC = tools.cc,
            .ocaml_cc_vendor = tools.cc_vendor,
            .outputobj = "-o ",
            .cc_has_debug_prefix_map = true,
            .ocaml_cv_prog_as_debug_prefix_map = false,
            .as_is_cc = true,
            .bytecode_cflags = cflags_,
            .bytecode_cppflags = cppflags,
            .native_cflags = cflags_,
            .native_cppflags = cppflags,
            .zstd_libs = o.features.zstd_libs orelse "",
            .cclibs = "-lpthread",
            .native_ldflags = "",
            .with_nonexecstack_note = t.nonexecstackNote(),
            .PACKLD = if (tools.packld) |p| .{ .parts = .{ p, "" } } else .{ .parts = .{ tools.cc, "-r -o " } },
            .rpath = if (darwin) "" else "-Wl,-rpath,",
            .mksharedlibrpath = if (darwin) "" else "-Wl,-rpath,",
            .AR = tools.ar,
            .supports_shared_libraries = Target.supports_shared_libraries,
            .natdynlink = t.natdynlink(),
            .mkdll_exp = .{ .parts = .{ tools.cc, mkdllFlags(t) } },
            .mkexe_exp = .{ .parts = .{ tools.cc, mkexeFlags(t) } },
            .mkmaindll_exp = .{ .parts = .{ tools.cc, mkdllFlags(t) } },

            .flambda = false,
            .flambda_invariants = false,
            .cmm_invariants = false,
            .codegen_invariants = o.codegen_invariants,
            .windows_unicode = 0,
            .flat_float_array = o.features.flat_float_array,
            .align_double = t.alignDouble(),
            .align_int64 = t.alignInt64(),
            .function_sections = t.functionSections(),
            .afl = false,
            .bytecode_runtime_id = ids.bytecode,
            .native_runtime_id = ids.native,
            .native_compiler = t.native,
            .arch = @tagName(t.arch),
            .model = t.model,
            .system = t.system,
            .target_os_type = Target.os_type,
            .AS = if (tools.asm_) |a|
                .{ .parts = .{ a, "" } }
            else
                .{ .parts = .{ tools.cc, if (darwin) "-c -Wno-trigraphs" else "-c" } },
            .asm_cfi_supported = t.asmCfiSupported(),
            .asm_size_type_directives = t.asmSizeTypeDirectives(),
            .asm_dwarf_version = "Some 4",
            .frame_pointers = o.features.frame_pointers,
            .reserved_header_bits = o.features.reserved_header_bits,
            .EXEEXT = e.exe,
            .OBJEXT = e.obj,
            .S = e.asm_,
            .libext = e.lib,
            .SO = e.dll,
            .host = o.host.triple(),
            .target = t.triple(),
            .systhread_support = true,
            .flexdll_dir = "",
            .ar_supports_response_files = true,
            .tsan = o.features.tsan,
            .shebangscripts = true,
            .suffixing = true,
            .launch_method_target = "sh",
            .runtime_search_target = "",

            .QS = .{ .n = 0 },
        };
        s.QS = try template.quotedStringId(Substs, &s);
        return s;
    }
};

/// `runtime/build_config.h`, normally written by make + `sak`.
pub const BuildConfigH = struct {
    stdlib_dir: []const u8,
    host: []const u8,
    bytecode_runtime_id: [4]u8,

    pub fn init(o: Options) BuildConfigH {
        return .{
            .stdlib_dir = stdlibDir(o),
            // `$(HOST)` in the Makefile.
            .host = o.host.triple(),
            .bytecode_runtime_id = runtimeIds(o).bytecode,
        };
    }

    pub fn format(h: BuildConfigH, w: *Writer) Writer.Error!void {
        try w.writeAll("/* Generated by zcaml */\n#define OCAML_STDLIB_DIR ");
        try template.writeCLiteral(w, h.stdlib_dir);
        try w.print("\n#define HOST \"{s}\"\n#define BYTECODE_RUNTIME_ID \"{s}\"\n", .{ h.host, &h.bytecode_runtime_id });
    }
};

pub const LdConf = struct {
    shared_libs: bool,

    pub fn init(o: Options) LdConf {
        _ = o;
        return .{ .shared_libs = Target.supports_shared_libraries };
    }

    pub fn format(c: LdConf, w: *Writer) Writer.Error!void {
        try w.writeAll(if (c.shared_libs) "./stublibs\n.\n" else ".\n");
    }
};

fn stdlibDir(o: Options) []const u8 {
    return switch (o.layout) {
        .absolute => |a| a.libdir,
        .relative => |r| r.bindir_to_libdir,
    };
}

const CFlags = Join(4);

/// `$common_cflags $sharedlib_cflags $PTHREAD_CFLAGS`.
fn cflags(t: *const Target) CFlags {
    return .{ .parts = .{
        if (t.needsNoPie()) "-no-pie" else "",
        "-O2 -fno-strict-aliasing -fwrapv",
        if (t.isDarwin()) "" else "-fPIC",
        "-pthread",
    } };
}

fn mkexeFlags(t: *const Target) []const u8 {
    return switch (t.zig.os.tag) {
        .macos => if (t.arch == .amd64) "-Wl,-no_compact_unwind" else "",
        else => "-Wl,-E",
    };
}

fn mkdllFlags(t: *const Target) []const u8 {
    return switch (t.zig.os.tag) {
        .macos => if (t.arch == .amd64)
            "-shared -undefined dynamic_lookup -Wl,-no_compact_unwind -Wl,-w"
        else
            "-shared -undefined dynamic_lookup -Wl,-w",
        // Disable DT_TEXTREL warnings on i386 (ocaml/ocaml#9800).
        else => if (t.arch == .i386) "-shared -Wl,-z,notext" else "-shared",
    };
}

const RuntimeIds = struct { zinc: [4]u8, bytecode: [4]u8, native: [4]u8 };

/// `OCAML_RUNTIME_ID` in configure.ac: four base-32 digits encoding the
/// options that make runtimes ABI-incompatible with each other.
fn runtimeIds(o: Options) RuntimeIds {
    const alphabet = "0123456789abcdefghijklmnopqrstuv";
    const t = o.target;
    const f = o.features;
    const reserved_header_bits: u32 = f.reserved_header_bits;
    const windows_ansi = false;

    const id_version: u32 = (o.version.release_number << 1) + @intFromBool(o.version.development);
    const q0 = alphabet[id_version & 31];
    const q1_zinc = id_version >> 5;
    const q1 = q1_zinc + (reserved_header_bits * 4) % 32;
    var q2_byte = reserved_header_bits / 8;
    var q2_zinc: u32 = 0;
    if (!f.flat_float_array) {
        q2_byte += 4;
        q2_zinc = 4;
    }
    var q2_native = q2_byte;
    if (f.frame_pointers) q2_native += 8;
    if (f.tsan) q2_native += 16;
    var q3_zinc: u32 = if (t.is64()) 0 else 1;
    if (!Target.supports_shared_libraries) q3_zinc += 2;
    if (!f.zstd()) q3_zinc += 4;
    const q3 = q3_zinc + if (windows_ansi) @as(u32, 8) else 0;

    return .{
        .zinc = .{ q0, alphabet[q1_zinc], alphabet[q2_zinc], alphabet[q3_zinc] },
        .bytecode = .{ q0, alphabet[q1], alphabet[q2_byte], alphabet[q3] },
        .native = .{ q0, alphabet[q1], alphabet[q2_native], alphabet[q3] },
    };
}
