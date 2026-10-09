//! The C runtime for one target: `libcamlrun`, `libasmrun` and `ocamlrun`.
//!
//! Every module here sets `sanitize_c = .off`: the runtime does deliberate
//! type punning and pointer arithmetic that UBSan rejects (the interpreter
//! reconstructs `pc` from a `value` on the OCaml stack, for one)

const std = @import("std");
const LazyPath = std.Build.LazyPath;
const Compile = std.Build.Step.Compile;

const OCaml = @import("OCaml.zig");
const Sources = @import("Sources.zig");
const Target = @import("Target.zig");

const Runtime = @This();

const Backend = Sources.Backend;

b: *std.Build,
target: std.Build.ResolvedTarget,
info: Target,
optimize: std.builtin.OptimizeMode,
src: LazyPath,
/// `caml/{m,s,version,exec}.h` and `build_config.h`.
generated: LazyPath,
/// `prims.c` and `caml/{opnames,jumptbl}.h`.
primitives: LazyPath,
zstd: *Compile,
cflags: []const []const u8,
sources: *const Sources,
platform: Sources.Platform,

libs: std.AutoArrayHashMapUnmanaged(Lib, *Compile) = .empty,
runs: std.EnumMap(Flavor, *Compile) = .{},
comprmarsh_lib: ?*Compile = null,

pub fn init(
    ocaml: *OCaml,
    sources: *const Sources,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !Runtime {
    const b = ocaml.b;
    const info = Target.resolve(target.result) catch |err| {
        std.log.err("unsupported target '{s}'", .{try target.result.zigTriple(b.allocator)});
        return err;
    };

    const gen = ocaml.gen;
    const platform: Sources.Platform = if (info.isWindows()) .win32 else .unix;

    const generated = gen.configure(b, .{
        .host = target,
        .target = target,
        .toolchain = ocaml.toolchain,
    });

    const primitives = prims: {
        const runtime_files = try sources.runtimeFiles(b.allocator, .bytecode, platform);
        break :prims gen.primitives(b, runtime_files);
    };

    const zstd = b.dependency("zstd", .{
        .target = target,
        .optimize = .ReleaseFast,
        // Only the streaming API is reachable from `runtime/zstd.c`.
        .dictbuilder = false,
        .deprecated = false,
        .@"legacy-support" = @as(usize, 0),
    }).artifact("zstd");

    return .{
        .b = b,
        .target = target,
        .info = info,
        .optimize = optimize,
        .src = ocaml.src,
        .generated = generated,
        .primitives = primitives,
        .zstd = zstd,
        .cflags = try computeCflags(b, &info),
        .sources = sources,
        .platform = platform,
    };
}

pub fn library(r: *Runtime, lib: Lib) *Compile {
    const gop = r.libs.getOrPut(r.b.allocator, lib) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = r.createLibrary(lib);
    return gop.value_ptr.*;
}

pub fn ocamlrun(r: *Runtime, flavor: Flavor) *Compile {
    return r.runs.get(flavor) orelse blk: {
        const b = r.b;

        const ocamlrun_mod = b.createModule(.{
            .target = r.target,
            .optimize = r.optimize,
            .link_libc = true,
            .sanitize_c = .off,
        });
        r.addCommon(ocamlrun_mod, .bytecode, flavor);
        ocamlrun_mod.addCSourceFile(.{
            .file = r.primitives.path(b, "runtime/prims.c"),
            .flags = r.cflags,
        });
        ocamlrun_mod.linkLibrary(r.library(.{ .backend = .bytecode, .flavor = flavor }));

        const ocamlrun_exe = b.addExecutable(.{
            .name = b.fmt("ocamlrun{s}", .{flavor.suffix()}),
            .root_module = ocamlrun_mod,
        });
        ocamlrun_exe.pie = if (r.info.needsNoPie()) false else null;

        r.runs.put(flavor, ocamlrun_exe);
        break :blk ocamlrun_exe;
    };
}

/// `runtime/zstd.c` alone, linked into native executables separately so that
/// programs which never marshal avoid the zstd dependency.
pub fn comprmarsh(r: *Runtime) *Compile {
    return r.comprmarsh_lib orelse blk: {
        const b = r.b;

        const comprmarsh_mod = b.createModule(.{
            .target = r.target,
            .optimize = r.optimize,
            .link_libc = true,
            .sanitize_c = .off,
            .pic = true,
        });

        r.addCommon(comprmarsh_mod, .native, .normal);
        comprmarsh_mod.addCSourceFile(.{
            .file = r.src.path(b, "runtime/zstd.c"),
            .flags = r.cflags,
        });
        comprmarsh_mod.linkLibrary(r.zstd);

        const comprmarsh_lib = b.addLibrary(.{
            .name = "comprmarsh",
            .linkage = .static,
            .root_module = comprmarsh_mod,
        });

        r.comprmarsh_lib = comprmarsh_lib;
        break :blk comprmarsh_lib;
    };
}

/// `runtime_*_OBJECTS` in the Makefile: the same objects with different
/// defines.
pub const Flavor = enum {
    normal,
    /// `-DDEBUG`, plus `instrtrace.c`. Named `*d`.
    debug,
    /// `-DCAML_INSTR`. Named `*i`.
    instrumented,

    fn suffix(f: Flavor) []const u8 {
        return switch (f) {
            .normal => "",
            .debug => "d",
            .instrumented => "i",
        };
    }

    fn cppDefine(f: Flavor) ?[]const u8 {
        return switch (f) {
            .normal => null,
            .debug => "DEBUG",
            .instrumented => "CAML_INSTR",
        };
    }
};

pub const Lib = struct {
    backend: Backend,
    flavor: Flavor = .normal,
    /// The `_pic` variant that goes into shared objects.
    pic: bool = false,

    fn name(l: Lib, b: *std.Build) []const u8 {
        return b.fmt("{s}run{s}{s}", .{
            switch (l.backend) {
                .bytecode => "caml",
                .native => "asm",
            },
            l.flavor.suffix(),
            if (l.pic) "_pic" else "",
        });
    }
};

fn createLibrary(r: *Runtime, l: Lib) *Compile {
    const b = r.b;
    const lib = b.addLibrary(.{
        .name = l.name(b),
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = r.target,
            .optimize = r.optimize,
            .link_libc = true,
            .sanitize_c = .off,
            .pic = if (l.pic) true else null,
        }),
    });
    r.addCommon(lib.root_module, l.backend, l.flavor);

    lib.root_module.addCSourceFiles(.{
        .root = r.src,
        .files = r.sources.runtimeFiles(b.allocator, l.backend, r.platform) catch @panic("OOM"),
        .flags = r.cflags,
    });
    if (l.flavor == .debug) lib.root_module.addCSourceFiles(.{
        .root = r.src,
        .files = r.sources.runtimeDebugFiles(b.allocator) catch @panic("OOM"),
        .flags = r.cflags,
    });
    if (l.backend == .native) {
        lib.root_module.addAssemblyFile(r.src.path(b, b.fmt("runtime/{s}.S", .{@tagName(r.info.arch)})));
    }
    return lib;
}

fn addCommon(r: *Runtime, m: *std.Build.Module, backend: Backend, flavor: Flavor) void {
    const b = r.b;
    // Upstream writes the generated headers into the source tree, so a quoted
    // `#include "m.h"` from `caml/config.h` finds its sibling. Ours live in
    // separate trees, so `runtime/caml` is searched explicitly, generated
    // directories first (the tarball only has `.in` templates for those).
    inline for (&.{ r.generated, r.primitives, r.src }) |root| {
        m.addIncludePath(root.path(b, "runtime"));
        m.addIncludePath(root.path(b, "runtime/caml"));
    }

    // CAMLDLLIMPORT is emptied so the runtime's own references to its symbols
    // are not marked `dllimport`.
    m.addCMacro("CAMLDLLIMPORT", "");
    m.addCMacro("IN_CAML_RUNTIME", "1");
    if (flavor.cppDefine()) |macro| m.addCMacro(macro, "1");

    switch (backend) {
        // `zstd.c` is in `runtime_BYTECODE_ONLY_C_SOURCES`; native programs
        // get it through `libcomprmarsh`.
        .bytecode => m.linkLibrary(r.zstd),
        .native => {
            m.addCMacro("NATIVE_CODE", "1");
            m.addCMacro(b.fmt("TARGET_{s}", .{@tagName(r.info.arch)}), "1");
            m.addCMacro(b.fmt("MODEL_{s}", .{r.info.model}), "1");
            m.addCMacro(b.fmt("SYS_{s}", .{r.info.system}), "1");
        },
    }

    // zig links libc and libm itself and `-pthread` covers pthreads, so only
    // the platform extras from `$cclibs` remain.
    if (r.info.isWindows()) {
        inline for (&.{
            "ws2_32", "ole32", "uuid", "version", "shlwapi", "synchronization",
        }) |lib| m.linkSystemLibrary(lib, .{});
    } else if (r.info.zig.os.tag == .linux) {
        m.linkSystemLibrary("dl", .{});
    }
}

fn computeCflags(b: *std.Build, info: *const Target) ![]const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(b.allocator, &.{
        // The runtime relies on signed overflow wrapping and puns `value`
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
    });
    if (info.functionSections()) try flags.append(b.allocator, "-ffunction-sections");
    if (!info.isWindows()) try flags.append(b.allocator, "-D_FILE_OFFSET_BITS=64");
    return flags.toOwnedSlice(b.allocator);
}
