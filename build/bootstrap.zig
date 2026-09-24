const std = @import("std");
const State = @import("state.zig");
const tools = @import("tools.zig");
const version_h = @import("config/version_h.zig");
const exec_h = @import("config/exec_h.zig");
const m_h = @import("config/m_h.zig");
const s_h = @import("config/s_h.zig");
const Config = @import("config/static.zig");
const TargetConfig = @import("config/target.zig");

pub const Ocamlrun = struct {
    module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
};

/// Builds the initial bytecode runtime for the selected target.
pub fn bootstrapOcamlrun(state: *State) !Ocamlrun {
    State.requireLinuxTarget("bootstrap.zig", &state.target.result);

    const mod = state.b.createModule(.{
        .target = state.target,
        .optimize = state.optimize,
        .link_libc = true,
        .pic = true,
    });

    mod.addCSourceFiles(.{
        .language = .c,
        .root = state.ocamlRel("runtime"),
        .files = &source_names,
        .flags = &common_c_flags,
    });

    const generated_headers = state.b.addWriteFiles();
    _ = generated_headers.addCopyFile(version_h.generate(state), "version.h");
    _ = generated_headers.addCopyFile(version_h.generate(state), "caml/version.h");
    _ = generated_headers.addCopyFile(exec_h.generate(state), "exec.h");
    _ = generated_headers.addCopyFile(exec_h.generate(state), "caml/exec.h");
    _ = generated_headers.addCopyFile(m_h.generate(state), "m.h");
    _ = generated_headers.addCopyFile(m_h.generate(state), "caml/m.h");
    _ = generated_headers.addCopyFile(s_h.generate(state), "s.h");
    _ = generated_headers.addCopyFile(s_h.generate(state), "caml/s.h");

    const triple = TargetConfig.ocamlTriple(state.b.allocator, state.target.result);
    const build_config = try std.fmt.allocPrint(
        state.b.allocator,
        "#define OCAML_STDLIB_DIR \"\"\n#define HOST \"{s}\"\n#define BYTECODE_RUNTIME_ID \"{s}\"\n",
        .{ triple, Config.bytecodeRuntimeId(state.target.result) },
    );
    _ = generated_headers.add("build_config.h", build_config);

    mod.addIncludePath(state.ocamlRel("runtime"));
    mod.addIncludePath(generated_headers.getDirectory());
    mod.addIncludePath(state.zstd.getEmittedIncludeTree());

    const gen_prims = tools.addZigRun(
        state.b,
        "zcaml-gen-ocaml-prims",
        state.b.path("tools/gen-prims.zig"),
    );
    const prims_run = gen_prims.run(state.b).outFile("prims.c");
    for (source_names) |source_name| {
        const source_path = try std.fmt.allocPrint(state.b.allocator, "runtime/{s}", .{source_name});
        _ = prims_run.inFile(state.ocamlRel(source_path));
    }
    mod.addCSourceFile(.{
        .file = prims_run.popOutFile(),
        .language = .c,
        .flags = &common_c_flags,
    });

    const jumptbl = tools.addZigRun(
        state.b,
        "zcaml-gen-jumptable",
        state.b.path("tools/gen-jumptbl.zig"),
    )
        .run(state.b)
        .outFile("jumptbl.h")
        .inFile(state.ocamlRel("runtime/caml/instruct.h"))
        .popOutFile();
    _ = generated_headers.addCopyFile(jumptbl, "caml/jumptbl.h");

    mod.linkLibrary(state.zstd);
    mod.linkSystemLibrary("pthread", .{});

    const exe = state.b.addExecutable(.{
        .name = "ocamlrun",
        .root_module = mod,
    });

    return Ocamlrun{
        .module = mod,
        .exe = exe,
    };
}

const source_names = [_][]const u8{
    "addrmap.c",
    "afl.c",
    "alloc.c",
    "array.c",
    "backtrace.c",
    "backtrace_byt.c",
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
    "fail_byt.c",
    "fiber.c",
    "finalise.c",
    "fix_code.c",
    "floats.c",
    "gc_ctrl.c",
    "gc_stats.c",
    "globroots.c",
    "hash.c",
    "intern.c",
    "interp.c",
    "ints.c",
    "io.c",
    "lexing.c",
    "lf_skiplist.c",
    "major_gc.c",
    "main.c",
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
    "startup_byt.c",
    "str.c",
    "sync.c",
    "sys.c",
    "unix.c",
    "weak.c",
    "zstd.c",
};

const common_c_flags = [_][]const u8{
    "-std=gnu11",
    "-D_FILE_OFFSET_BITS=64",
    "-fno-strict-aliasing",
    "-fwrapv",
};
