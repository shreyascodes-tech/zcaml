const std = @import("std");
const State = @import("../state.zig");
const Config = @import("static.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(state: *State) LazyPath {
    const target = state.result();
    State.requireLinuxTarget("m_h.zig", target);

    const pointer_bits = target.ptrBitWidth();
    const pointer_size = @divExact(pointer_bits, 8);
    const int_size = target.cTypeByteSize(.int);
    const long_size = target.cTypeByteSize(.long);
    const short_size = target.cTypeByteSize(.short);
    const longlong_size = target.cTypeByteSize(.longlong);
    const double_alignment = target.cTypeAlignment(.double);
    const long_alignment = target.cTypeAlignment(.long);
    const longlong_alignment = target.cTypeAlignment(.longlong);

    // OCaml's 32-bit configuration needs these C ABI invariants.  Keep the
    // check here so an invalid target fails while the build graph is formed.
    if (int_size != 4 or short_size != 2 or longlong_size != 8 or
        (long_size != 4 and long_size != 8))
    {
        std.debug.panic(
            "m_h.zig: unsupported target {s}-{s}-{s} (object format {s}, {d}-bit pointers); invalid OCaml C ABI",
            .{
                @tagName(target.cpu.arch),
                @tagName(target.os.tag),
                @tagName(target.abi),
                @tagName(target.ofmt),
                pointer_bits,
            },
        );
    }

    const is_64 = pointer_bits == 64;
    const is_elf = target.ofmt == .elf;
    const is_big_endian = target.cpu.arch.endian() == .big;
    const align_double = is_elf and !is_64 and double_alignment > 4;
    const align_int64 = is_elf and !is_64 and
        ((long_size == 8 and long_alignment > 4) or
            (longlong_size == 8 and longlong_alignment > 4));
    const has_code32 = is_64 and target.cpu.arch == .x86_64;

    return tools.configHeader(
        state.ctx.b,
        state.ctx.ocamlRel("runtime/caml/m.h.in"),
        &.{
            .{ "ARCH_SIXTYFOUR", .flagOrNull(is_64) },
            .{ "ARCH_BIG_ENDIAN", .flagOrNull(is_big_endian) },
            .{ "ARCH_ALIGN_DOUBLE", .flagOrNull(align_double) },
            .{ "HAS_ARCH_CODE32", .flagOrNull(has_code32) },
            .{ "SIZEOF_INT", .int(@as(i64, @intCast(int_size))) },
            .{ "SIZEOF_LONG", .int(@as(i64, @intCast(long_size))) },
            .{ "SIZEOF_PTR", .int(@as(i64, @intCast(pointer_size))) },
            .{ "SIZEOF_SHORT", .int(@as(i64, @intCast(short_size))) },
            .{ "SIZEOF_LONGLONG", .int(@as(i64, @intCast(longlong_size))) },
            .{ "ARCH_ALIGN_INT64", .flagOrNull(align_int64) },
            .{ "HEADER_RESERVED_BITS", .int(Config.config.header_reserved_bits) },
            .{ "ASM_CFI_SUPPORTED", .flagOrNull(is_elf) },
            .{ "ASM_SIZE_TYPE_DIRECTIVES", .flagOrNull(is_elf) },
            .{ "WITH_FRAME_POINTERS", .flagOrNull(false) },
            .{ "CAML_WITH_FPIC", .flagOrNull(false) },
            .{ "FLAT_FLOAT_ARRAY", .flagOrNull(true) },
            .{ "FUNCTION_SECTIONS", .flagOrNull(is_elf) },
            // Keep optional target probes disabled until a caller explicitly
            // opts in; this configuration is intentionally probe-free.
            .{ "SUPPORTS_ALIGNED_ATTRIBUTE", .flagOrNull(false) },
            // The fixed Zig clang policy supports the GNU attribute used by
            // the runtime, so no compiler probe is needed.
            .{ "SUPPORTS_TREE_VECTORIZE", .flagOrNull(false) },
            // MAP_STACK changes the runtime allocator and is not assumed
            // without a target probe.
            .{ "USE_MMAP_MAP_STACK", .flagOrNull(false) },
            .{ "WITH_NONEXECSTACK_NOTE", .flagOrNull(is_elf) },
        },
    );
}
