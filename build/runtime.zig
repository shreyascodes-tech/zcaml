//! The C runtime: `libcamlrun` (the bytecode interpreter's support library),
//! `libasmrun` (linked into native executables) and the `ocamlrun` program.
//!
//! This is the only part of OCaml that the C toolchain compiles, so it is the
//! only part that has to be built once per target.
//!
//! Every module here sets `sanitize_c = .off`. The runtime does a great deal
//! of deliberate type punning and pointer arithmetic that UBSan rejects (the
//! bytecode interpreter reconstructs `pc` from a `value` held on the OCaml
//! stack, for one), and upstream never builds it with sanitizers. Leaving them
//! on makes `ocamlrun` trap as soon as a signal is delivered.

const std = @import("std");

const Target = @import("Target.zig");
const configure = @import("configure.zig");
const sources = @import("sources.zig");

/// Which set of C sources and preprocessor defines to use. A single `.c` file
/// is compiled once per backend, because `NATIVE_CODE` changes the GC's view
/// of the stack and the shape of exception handling.
pub const Backend = enum { bytecode, native };

/// `runtime_*_OBJECTS` in the Makefile: the same objects built with different
/// defines, producing `libcamlrun`, `libcamlrund`, `libcamlruni` and
/// `libcamlrun_pic` (and the `libasmrun` equivalents).
pub const Flavor = enum {
    /// `libcamlrun` / `libasmrun`.
    normal,
    /// `-DDEBUG`: also links `instrtrace.c`, which traces every bytecode
    /// instruction. Named `*d`.
    debug,
    /// `-DCAML_INSTR`. Named `*i`.
    instrumented,
    /// `-fPIC`, for `libcamlrun_pic` and the `_shared` DLLs.
    pic,

    fn suffix(f: Flavor) []const u8 {
        return switch (f) {
            .normal => "",
            .debug => "d",
            .instrumented => "i",
            .pic => "_pic",
        };
    }

    fn cppDefine(f: Flavor) ?[]const u8 {
        return switch (f) {
            .normal, .pic => null,
            .debug => "DEBUG",
            .instrumented => "CAML_INSTR",
        };
    }
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    /// What `configure.zig` decided about `target`.
    info: *const Target,
    optimize: std.builtin.OptimizeMode,
    /// `ocaml-gen configure` output: supplies `caml/{m,s,version,exec}.h` and
    /// `build_config.h`.
    generated: std.Build.LazyPath,
    /// `ocaml-gen primitives` output: supplies `prims.c` and
    /// `caml/{opnames,jumptbl}.h`.
    primitives: std.Build.LazyPath,
    /// The unpacked OCaml tarball.
    src: std.Build.LazyPath,
    /// Compressed marshalling (`HAS_ZSTD`). Linked into the bytecode runtime
    /// directly, and into native executables through `libcomprmarsh`.
    zstd: *std.Build.Step.Compile,
};

/// Builds one runtime library. `ocamlrun` links the bytecode flavour;
/// `ocamlopt` links the native one into every executable it produces.
pub fn library(b: *std.Build, o: Options, backend: Backend, flavor: Flavor) *std.Build.Step.Compile {
    const name = b.fmt("{s}run{s}", .{
        switch (backend) {
            .bytecode => "caml",
            .native => "asm",
        },
        flavor.suffix(),
    });

    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .sanitize_c = .off,
            // `libcamlrun_pic` is linked into shared libraries; the other
            // flavours go into executables.
            .pic = if (flavor == .pic) true else null,
        }),
    });
    addCommon(b, lib.root_module, o, backend, flavor);

    const files = switch (backend) {
        .bytecode => if (o.info.isWindows())
            sources.runtime(.bytecode, .win32)
        else
            sources.runtime(.bytecode, .unix),
        .native => if (o.info.isWindows())
            sources.runtime(.native, .win32)
        else
            sources.runtime(.native, .unix),
    };
    lib.root_module.addCSourceFiles(.{
        .root = o.src.path(b, "runtime"),
        .files = files,
        .flags = cflags(b, o),
    });
    if (flavor == .debug) lib.root_module.addCSourceFiles(.{
        .root = o.src.path(b, "runtime"),
        .files = &sources.runtime_debug_only,
        .flags = cflags(b, o),
    });

    // The native runtime's stack switching, GC entry points and C-call
    // trampolines are hand-written assembly, one file per architecture.
    if (backend == .native) {
        lib.root_module.addAssemblyFile(o.src.path(b, b.fmt("runtime/{s}.S", .{
            @tagName(o.info.arch),
        })));
    }

    return lib;
}

/// The bytecode interpreter. `prims.c` is what makes it a program rather than
/// a library: it holds the tables that map bytecode `C_CALL` operands to the
/// C functions in `libcamlrun`.
pub fn ocamlrun(b: *std.Build, o: Options, flavor: Flavor) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = b.fmt("ocamlrun{s}", .{switch (flavor) {
            .normal => "",
            .debug => "d",
            .instrumented => "i",
            .pic => @panic("ocamlrun has no pic flavour"),
        }}),
        .root_module = b.createModule(.{
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    addCommon(b, exe.root_module, o, .bytecode, flavor);
    exe.root_module.addCSourceFile(.{
        .file = o.primitives.path(b, "runtime/prims.c"),
        .flags = cflags(b, o),
    });
    exe.root_module.linkLibrary(library(b, o, .bytecode, flavor));
    return exe;
}

/// `libcomprmarsh`: `runtime/zstd.c` alone, linked into native executables
/// separately so that programs which never marshal avoid the zstd dependency.
pub fn comprmarsh(b: *std.Build, o: Options) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "comprmarsh",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .sanitize_c = .off,
            .pic = true,
        }),
    });
    addCommon(b, lib.root_module, o, .native, .pic);
    lib.root_module.addCSourceFile(.{
        .file = o.src.path(b, "runtime/zstd.c"),
        .flags = cflags(b, o),
    });
    return lib;
}

/// Include paths, defines and system libraries shared by every runtime object.
fn addCommon(
    b: *std.Build,
    m: *std.Build.Module,
    o: Options,
    backend: Backend,
    flavor: Flavor,
) void {
    // `OC_INCLUDES`, except that upstream writes the generated headers into
    // the source tree, so a quoted `#include "m.h"` from `caml/config.h`
    // finds its sibling. Ours live in separate trees, so `runtime/caml` has
    // to be searched explicitly as well. The generated directories come
    // first; the tarball only has `.in` templates for those headers.
    for ([_]std.Build.LazyPath{ o.generated, o.primitives, o.src }) |root| {
        m.addIncludePath(root.path(b, "runtime"));
        m.addIncludePath(root.path(b, "runtime/caml"));
    }

    // `runtime_CPPFLAGS`. CAMLDLLIMPORT is emptied so that the runtime's own
    // references to its symbols are not marked `dllimport`.
    m.addCMacro("CAMLDLLIMPORT", "");
    m.addCMacro("IN_CAML_RUNTIME", "1");
    if (flavor.cppDefine()) |macro| m.addCMacro(macro, "1");

    if (backend == .native) {
        // `oc_native_cppflags`: these pick the target-specific code paths in
        // the GC and the stack unwinder.
        m.addCMacro("NATIVE_CODE", "1");
        m.addCMacro(b.fmt("TARGET_{s}", .{@tagName(o.info.arch)}), "1");
        m.addCMacro(b.fmt("MODEL_{s}", .{o.info.model}), "1");
        m.addCMacro(b.fmt("SYS_{s}", .{o.info.system}), "1");
    }

    // `runtime/zstd.c` is the only user, but it is compiled into every
    // bytecode flavour, so the headers have to be visible throughout.
    m.linkLibrary(o.zstd);

    // `$cclibs`: zig links libc and libm itself, and `-pthread` in the flags
    // covers pthreads, so only the platform extras remain.
    if (o.info.isWindows()) {
        for ([_][]const u8{
            "ws2_32", "ole32", "uuid", "version", "shlwapi", "synchronization",
        }) |lib| m.linkSystemLibrary(lib, .{});
    } else if (o.info.zig.os.tag == .linux) {
        m.linkSystemLibrary("dl", .{});
    }
}

/// `$(OC_CFLAGS)` plus the few `$(OC_CPPFLAGS)` entries that are not defines.
/// Warnings are kept close to upstream's so that a new target's breakage shows
/// up as a warning rather than as a miscompile.
///
/// The optimisation level is deliberately absent: upstream hardcodes `-O2`,
/// but zig already passes one derived from `optimize`, and a second `-O` here
/// would silently win.
fn cflags(b: *std.Build, o: Options) []const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        // `$common_cflags`: `-fwrapv` because the runtime relies on signed
        // overflow wrapping, and no strict aliasing because `value` is punned
        // throughout.
        "-fno-strict-aliasing",
        "-fwrapv",
        "-pthread",
        "-Wall",
        "-Wint-conversion",
        "-Wstrict-prototypes",
        "-Wold-style-definition",
        "-Wundef",
        "-Wimplicit-fallthrough",
        "-fno-common",
    }) catch @panic("OOM");

    if (o.info.functionSections()) flags.append(b.allocator, "-ffunction-sections") catch @panic("OOM");
    if (!o.info.isWindows()) flags.append(b.allocator, "-D_FILE_OFFSET_BITS=64") catch @panic("OOM");
    if (o.info.needsNoPie()) flags.append(b.allocator, "-no-pie") catch @panic("OOM");

    return flags.toOwnedSlice(b.allocator) catch @panic("OOM");
}
