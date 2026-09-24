const std = @import("std");
const State = @import("../state.zig");
const Config = @import("static.zig");
const TargetConfig = @import("target.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(state: *State) LazyPath {
    const target_info = targetInfo(state, state.target.result);
    const host_triple = TargetConfig.ocamlTriple(state.b.allocator, state.b.graph.host.result);
    const bytecode_cppflags = if (target_info.is_unix)
        Config.config.file_offset_bits
    else
        Config.config.empty;
    const cflags = if (target_info.is_unix)
        Config.config.unix_cflags
    else
        Config.config.other_cflags;
    const c_output_obj = if (target_info.is_msvc)
        Config.config.windows_obj_flag
    else
        Config.config.other_obj_flag;
    const launch_method = if (target_info.is_unix)
        Config.config.unix_launch_method
    else
        Config.config.other_launch_method;
    const zstd_libs = zstdLibrary(state);

    return tools.replaceAll(
        state.b,
        state.ocamlRel("utils/config.generated.ml.in"),
        "config.generated.ml",
        &.{
            .once("@configure_input@", .str(Config.input.common)),
            .all("@QS@", .str(Config.config.qs)),
            .once("@ocaml_bindir@", .str(Config.config.empty)),
            .once("@TARGET_BINDIR@", .str(Config.config.empty)),
            .once("@ccomp_type@", .str(Config.config.ccomp_type)),
            .once("@CC@", .str(Config.config.c_compiler)),
            .once("@ocaml_cc_vendor@", .str(Config.config.c_compiler_vendor)),
            .once("@outputobj@", .str(c_output_obj)),
            .once("@cc_has_debug_prefix_map@", .str(Config.config.yes)),
            .once("@ocaml_cv_prog_as_debug_prefix_map@", .str(Config.config.no)),
            .once("@as_is_cc@", .str(Config.config.yes)),
            .once("@bytecode_cflags@", .str(cflags)),
            .once("@bytecode_cppflags@", .str(bytecode_cppflags)),
            .once("@native_cflags@", .str(cflags)),
            .once("@native_cppflags@", .str(target_info.native_cppflags)),
            .all("@zstd_libs@", .str(zstd_libs)),
            .all("@cclibs@", .str(target_info.cclibs)),
            .once("@native_ldflags@", .str(Config.config.empty)),
            .once("@with_nonexecstack_note@", .str(if (target_info.is_elf) Config.config.yes else Config.config.no)),
            .once("@PACKLD@", .str(Config.config.packld)),
            .once("@rpath@", .str(Config.config.empty)),
            .once("@mksharedlibrpath@", .str(Config.config.empty)),
            .once("@AR@", .str(Config.config.ar)),
            .once("@supports_shared_libraries@", .str(if (target_info.is_unix) Config.config.yes else Config.config.no)),
            .once("@natdynlink@", .str(if (target_info.is_unix) Config.config.yes else Config.config.no)),
            .once("@mkdll_exp@", .str(if (target_info.is_unix) Config.config.unix_mkdll else Config.config.empty)),
            .once("@mkexe_exp@", .str(if (target_info.is_unix) Config.config.unix_mkexe else Config.config.empty)),
            .once("@mkmaindll_exp@", .str(if (target_info.is_unix) Config.config.unix_mkmaindll else Config.config.empty)),
            .once("@flambda@", .str(Config.config.no)),
            .once("@flambda_invariants@", .str(Config.config.no)),
            .once("@cmm_invariants@", .str(Config.config.no)),
            .once("@codegen_invariants@", .str(Config.config.yes)),
            .once("@windows_unicode@", .str(if (target_info.is_windows) Config.config.one else Config.config.zero)),
            .once("@flat_float_array@", .str(Config.config.yes)),
            .once("@align_double@", .str(if (target_info.align_double) Config.config.yes else Config.config.no)),
            .once("@align_int64@", .str(if (target_info.align_int64) Config.config.yes else Config.config.no)),
            .once("@function_sections@", .str(if (target_info.is_elf) Config.config.yes else Config.config.no)),
            .once("@afl@", .str(Config.config.no)),
            .once("@bytecode_runtime_id@", .str(Config.bytecodeRuntimeId(state.target.result))),
            .once("@native_runtime_id@", .str(if (state.target.result.ptrBitWidth() == 64)
                Config.runtime_ids.native_64
            else
                Config.runtime_ids.native_32)),
            .once("@native_compiler@", .str(if (target_info.native_compiler) Config.config.yes else Config.config.no)),
            .once("@arch@", .str(target_info.architecture)),
            .once("@model@", .str(target_info.model)),
            .once("@system@", .str(target_info.system)),
            .once("@target_os_type@", .str(target_info.target_os_type)),
            .once("@AS@", .str(Config.config.assembler)),
            .once("@asm_cfi_supported@", .str(if (target_info.is_elf) Config.config.yes else Config.config.no)),
            .once("@asm_size_type_directives@", .str(if (target_info.is_elf) Config.config.yes else Config.config.no)),
            .once("@asm_dwarf_version@", .str(Config.config.none)),
            .once("@frame_pointers@", .str(Config.config.no)),
            .once("@reserved_header_bits@", .str(std.fmt.comptimePrint("{d}", .{Config.config.header_reserved_bits}))),
            .once("@EXEEXT@", .str(target_info.ext_exe)),
            .once("@OBJEXT@", .str(target_info.ext_obj)),
            .once("@S@", .str(target_info.ext_asm)),
            .once("@libext@", .str(target_info.ext_lib)),
            .once("@SO@", .str(target_info.ext_dll)),
            .once("@host@", .str(host_triple)),
            .once("@target@", .str(target_info.target_triple)),
            .once("@systhread_support@", .str(if (target_info.systhread_supported) Config.config.yes else Config.config.no)),
            .once("@flexdll_dir@", .str(Config.config.empty)),
            .once("@ar_supports_response_files@", .str(Config.config.yes)),
            .once("@tsan@", .str(Config.config.no)),
            .once("@shebangscripts@", .str(if (target_info.is_unix) Config.config.yes else Config.config.no)),
            .once("@suffixing@", .str(Config.config.yes)),
            .once("@launch_method_target@", .str(launch_method)),
            // Runtime search and installation paths are decided by later stages.
            .once("@runtime_search_target@", .str(Config.config.empty)),
        },
    );
}

fn zstdLibrary(state: *const State) []const u8 {
    // The install directory contains the target-built static archive, so this
    // does not ask the linker to discover a system zstd installation.
    return state.b.fmt("-L{s} {s}", .{
        state.b.getInstallPath(.lib, ""),
        Config.config.zstd_libs,
    });
}

const TargetInfo = struct {
    architecture: []const u8,
    model: []const u8,
    system: []const u8,
    target_os_type: []const u8,
    target_triple: []const u8,
    native_compiler: bool,
    is_64: bool,
    is_unix: bool,
    is_windows: bool,
    is_msvc: bool,
    is_elf: bool,
    align_double: bool,
    align_int64: bool,
    ext_exe: []const u8,
    ext_obj: []const u8,
    ext_asm: []const u8,
    ext_lib: []const u8,
    ext_dll: []const u8,
    cclibs: []const u8,
    native_cppflags: []const u8,
    systhread_supported: bool,
};

fn targetInfo(state: *const State, target: std.Target) TargetInfo {
    const arch = target.cpu.arch;
    const is_windows = target.os.tag == .windows;
    const is_msvc = is_windows and target.abi == .msvc;
    const is_unix = isUnixTarget(target.os.tag);
    const architecture = targetArchitecture(arch);
    const model = targetModel(target);
    const system = targetSystem(target);
    const target_triple = TargetConfig.ocamlTriple(state.b.allocator, target);
    const native_cppflags = if (is_unix)
        Config.config.file_offset_bits
    else
        Config.config.empty;

    const pointer_bits = target.ptrBitWidth();
    const is_64 = pointer_bits == 64;
    const is_elf = target.ofmt == .elf;
    const align_double = is_elf and !is_64 and
        target.cTypeAlignment(.double) > 4;
    const long_size = target.cTypeByteSize(.long);
    const long_alignment = target.cTypeAlignment(.long);
    const longlong_size = target.cTypeByteSize(.longlong);
    const longlong_alignment = target.cTypeAlignment(.longlong);
    const align_int64 = is_elf and !is_64 and
        ((long_size == 8 and long_alignment > 4) or
            (longlong_size == 8 and longlong_alignment > 4));

    return .{
        .architecture = architecture,
        .model = model,
        .system = system,
        .target_os_type = if (is_windows) Config.config.os_type_windows else Config.config.os_type_unix,
        .target_triple = target_triple,
        .native_compiler = nativeCompilerSupported(target),
        .is_64 = is_64,
        .is_unix = is_unix,
        .is_windows = is_windows,
        .is_msvc = is_msvc,
        .is_elf = is_elf,
        .align_double = align_double,
        .align_int64 = align_int64,
        .ext_exe = std.mem.trimStart(u8, target.exeFileExt(), "."),
        .ext_obj = if (target.abi == .msvc) Config.config.obj_msvc else Config.config.obj_other,
        .ext_asm = if (target.abi == .msvc) Config.config.asm_msvc else Config.config.asm_other,
        .ext_lib = std.mem.trimStart(u8, target.staticLibSuffix(), "."),
        .ext_dll = std.mem.trimStart(u8, target.dynamicLibSuffix(), "."),
        .cclibs = if (is_windows)
            Config.config.windows_cclibs
        else if (is_unix)
            Config.config.unix_cclibs
        else
            Config.config.empty,
        .native_cppflags = native_cppflags,
        .systhread_supported = is_unix,
    };
}

fn isUnixTarget(os: std.Target.Os.Tag) bool {
    return os.isBSD() or switch (os) {
        .linux, .haiku, .illumos, .hurd, .serenity => true,
        else => false,
    };
}

fn targetArchitecture(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch.family()) {
        .x86 => switch (arch) {
            .x86_64 => "amd64",
            .x86 => "i386",
            else => "none",
        },
        .aarch64 => if (arch == .aarch64) "arm64" else "none",
        .arm => switch (arch) {
            .arm, .thumb => "arm",
            else => "none",
        },
        .powerpc => "power",
        .riscv => if (arch == .riscv64) "riscv" else "none",
        .s390x => "s390x",
        else => "none",
    };
}

fn targetModel(target: std.Target) []const u8 {
    return switch (target.cpu.arch.family()) {
        .powerpc => switch (target.cpu.arch) {
            .powerpc64 => "ppc64",
            .powerpc64le => "ppc64le",
            else => "ppc",
        },
        .riscv => if (target.cpu.arch == .riscv64) "riscv64" else "default",
        .s390x => "z10",
        .arm => switch (target.cpu.arch) {
            .arm, .thumb => armModel(target.cpu.model.name),
            else => "default",
        },
        else => "default",
    };
}

fn armModel(name: []const u8) []const u8 {
    const models = [_]struct { prefix: []const u8, model: []const u8 }{
        .{ .prefix = "armv8", .model = "armv8" },
        .{ .prefix = "cortex_a53", .model = "armv8" },
        .{ .prefix = "cortex_a55", .model = "armv8" },
        .{ .prefix = "cortex_a57", .model = "armv8" },
        .{ .prefix = "cortex_a72", .model = "armv8" },
        .{ .prefix = "cortex_a73", .model = "armv8" },
        .{ .prefix = "cortex_a75", .model = "armv8" },
        .{ .prefix = "cortex_a76", .model = "armv8" },
        .{ .prefix = "cortex_a77", .model = "armv8" },
        .{ .prefix = "cortex_a78", .model = "armv8" },
        .{ .prefix = "armv7", .model = "armv7" },
        .{ .prefix = "cortex_a7", .model = "armv7" },
        .{ .prefix = "cortex_a8", .model = "armv7" },
        .{ .prefix = "cortex_a9", .model = "armv7" },
        .{ .prefix = "cortex_a12", .model = "armv7" },
        .{ .prefix = "cortex_a15", .model = "armv7" },
        .{ .prefix = "cortex_a17", .model = "armv7" },
        .{ .prefix = "armv6", .model = "armv6" },
        .{ .prefix = "cortex_a5", .model = "armv6" },
        .{ .prefix = "cortex_a11", .model = "armv6" },
    };

    for (models) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) return entry.model;
    }
    return "default";
}

fn targetSystem(target: std.Target) []const u8 {
    const is_64 = target.ptrBitWidth() == 64;
    if (target.os.tag.isDarwin()) return "macosx";
    return switch (target.os.tag) {
        .linux => "linux",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .dragonfly => "dragonfly",
        .haiku => "beos",
        .illumos => "solaris",
        .windows => if (target.abi == .msvc or target.abi == .itanium)
            (if (is_64) "win64" else "win32")
        else if (is_64) "mingw64" else "mingw",
        .freestanding, .other, .wasi => "none",
        else => "unknown",
    };
}

fn nativeCompilerSupported(target: std.Target) bool {
    if (target.os.tag == .wasi or target.os.tag == .freestanding) return false;
    return switch (target.cpu.arch.family()) {
        .x86 => target.cpu.arch == .x86 or target.cpu.arch == .x86_64,
        .aarch64 => target.cpu.arch == .aarch64,
        .arm => target.cpu.arch == .arm or target.cpu.arch == .thumb,
        .powerpc => true,
        .riscv => target.cpu.arch == .riscv64,
        .s390x => true,
        else => false,
    };
}
