//! Per-target OCaml build state.
//!
//! One State exists per target.  Get one from
//! `Context.forTarget` or `Context.host`, and don't create it directly.
//! Artifacts built for the target (runtimes, later stdlib/compilers) are
//! created lazily and cached here, so asking twice builds only once.

const std = @import("std");
const Context = @import("context.zig");
const runtime = @import("runtime.zig");

const State = @This();

ctx: *Context,

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,

/// The vendored zstd static library for this target.  Its emitted binary and
/// include tree remain lazy build paths.
zstd: *std.Build.Step.Compile,

bytecode_runtime: ?runtime.Bytecode = null,

/// Use `Context.forTarget` instead.
pub fn create(ctx: *Context, target: std.Build.ResolvedTarget) *State {
    const optimize = ctx.optimize;
    const b = ctx.b;
    const zstd_dep = b.dependency("zstd", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });
    const self = b.allocator.create(State) catch @panic("OOM");
    self.* = .{
        .ctx = ctx,
        .target = target,
        .optimize = optimize,
        .zstd = zstd_dep.artifact("zstd"),
    };
    return self;
}

pub fn result(self: *const State) *const std.Target {
    return &self.target.result;
}

/// Whether this is the State that runs build-time programs.
pub fn isHost(self: *State) bool {
    return self == self.ctx.host();
}

/// The bytecode runtime (`libcamlrun` + `ocamlrun`) for this target.
pub fn bytecodeRuntime(self: *State) *const runtime.Bytecode {
    if (self.bytecode_runtime == null) self.bytecode_runtime = runtime.bytecode(self);
    return &self.bytecode_runtime.?;
}

pub fn requireLinuxTarget(module: []const u8, target: *const std.Target) void {
    const pointer_bits = target.ptrBitWidth();
    if (target.os.tag != .linux or
        !(target.isGnuLibC() or target.isMuslLibC()) or
        target.ofmt != .elf or
        (pointer_bits != 32 and pointer_bits != 64))
    {
        std.debug.panic(
            "{s}: unsupported target {s}-{s}-{s} (object format {s}, {d}-bit pointers); expected Linux GNU/musl ELF with 32- or 64-bit pointers",
            .{
                module,
                @tagName(target.cpu.arch),
                @tagName(target.os.tag),
                @tagName(target.abi),
                @tagName(target.ofmt),
                pointer_bits,
            },
        );
    }
}
