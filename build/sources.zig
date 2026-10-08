//! Source lists transcribed from OCaml's root `Makefile`.
//!
//! These are data, not logic: when bumping the OCaml version, diff the
//! `Makefile` and update the lists here.

/// `runtime_COMMON_C_SOURCES`, minus the `$(UNIX_OR_WIN32)` entry which
/// `runtimeCommon` appends.
const runtime_common = [_][]const u8{
    "addrmap.c",
    "afl.c",
    "alloc.c",
    "array.c",
    "backtrace.c",
    "bigarray.c",
    "blake2.c",
    "callback.c",
    "codefrag.c",
    "compare.c",
    "custom.c",
    "debugger.c",
    "domain.c",
    "dynlink.c",
    "extern.c",
    "fail.c",
    "fiber.c",
    "finalise.c",
    "floats.c",
    "gc_ctrl.c",
    "gc_stats.c",
    "globroots.c",
    "hash.c",
    "intern.c",
    "ints.c",
    "io.c",
    "lexing.c",
    "lf_skiplist.c",
    "main.c",
    "major_gc.c",
    "md5.c",
    "memory.c",
    "memprof.c",
    "meta.c",
    "minor_gc.c",
    "misc.c",
    "obj.c",
    "parsing.c",
    "platform.c",
    "printexc.c",
    "prng.c",
    "roots.c",
    "runtime_events.c",
    "shared_heap.c",
    "signals.c",
    "skiplist.c",
    "startup_aux.c",
    "str.c",
    "sync.c",
    "sys.c",
    "weak.c",
};

/// `runtime_BYTECODE_ONLY_C_SOURCES`.
const runtime_bytecode_only = [_][]const u8{
    "backtrace_byt.c",
    "fail_byt.c",
    "fix_code.c",
    "interp.c",
    "startup_byt.c",
    "zstd.c",
};

/// `runtime_NATIVE_ONLY_C_SOURCES`, minus `$(TSAN_NATIVE_RUNTIME_C_SOURCES)`.
const runtime_native_only = [_][]const u8{
    "backtrace_nat.c",
    "clambda_checks.c",
    "dynlink_nat.c",
    "fail_nat.c",
    "frame_descriptors.c",
    "startup_nat.c",
    "signals_nat.c",
};

/// Only linked into the debug runtime (`libcamlrund`/`libasmrund`).
pub const runtime_debug_only = [_][]const u8{"instrtrace.c"};

pub const Platform = enum {
    unix,
    win32,

    fn source(p: Platform) []const u8 {
        return switch (p) {
            .unix => "unix.c",
            .win32 => "win32.c",
        };
    }
};

pub const Backend = enum { bytecode, native };

/// The C sources for one runtime flavour, in Makefile order so that the
/// declaration order in a generated `prims.c` is reproducible.
pub fn runtime(comptime backend: Backend, comptime platform: Platform) []const []const u8 {
    return comptime &(runtime_common ++ [_][]const u8{platform.source()} ++ switch (backend) {
        .bytecode => runtime_bytecode_only,
        .native => runtime_native_only,
    });
}

/// `ocamlyacc_MODULES`, minus the Windows-only `yacc/wstr`.
pub const ocamlyacc = [_][]const u8{
    "closure.c",
    "error.c",
    "lalr.c",
    "lr0.c",
    "main.c",
    "mkpar.c",
    "output.c",
    "reader.c",
    "skeleton.c",
    "symtab.c",
    "verbose.c",
    "warshall.c",
};
