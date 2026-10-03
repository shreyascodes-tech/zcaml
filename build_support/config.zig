const std = @import("std");
const Build = std.Build;

/// A single native bootstrap profile. The build machine runs the boot
/// compiler, the host runs the new runtime and ocamlc, and the target runs
/// programs emitted by that ocamlc. All three must be Linux x86_64 GNU.
pub const Config = struct {
    build: std.Target,
    host: std.Target,
    target: std.Target,
    profile: Profile,
    install_bin: []const u8,
    install_library: []const u8,

    pub const Profile = struct {
        host_triple: []const u8 = "x86_64-unknown-linux-gnu",
        os_type: []const u8 = "Unix",
        pointer_bytes: u8 = 8,
        flat_float_array: bool = true,

        // OCaml's configure sets ARCH_ALIGN_* only under `if ! $arch64`.
        // On this 64-bit profile, these macros stay undefined and the
        // corresponding config.generated.ml values are false.
        align_double: bool = false,
        align_int64: bool = false,
    };

    pub fn native(b: *Build) Config {
        const machine = b.graph.host.result;
        return .{
            .build = machine,
            .host = machine,
            .target = machine,
            .profile = .{},
            // The bootstrap compiler embeds the selected installation prefix.
            // Relocatable distribution packaging is a separate policy.
            .install_bin = b.getInstallPath(.bin, ""),
            .install_library = b.getInstallPath(.lib, "ocaml"),
        };
    }

    pub fn supported(self: Config) bool {
        return nativeLinuxGnu(self.build) and
            nativeLinuxGnu(self.host) and
            nativeLinuxGnu(self.target) and
            self.profile.pointer_bytes == 8 and
            self.profile.flat_float_array and
            !self.profile.align_double and
            !self.profile.align_int64 and
            std.mem.eql(u8, self.profile.os_type, "Unix") and
            std.mem.eql(u8, self.profile.host_triple, "x86_64-unknown-linux-gnu");
    }

    fn nativeLinuxGnu(machine: std.Target) bool {
        return machine.cpu.arch == .x86_64 and
            machine.os.tag == .linux and
            machine.abi == .gnu;
    }

    pub fn machineHeader(self: Config, b: *Build) *Build.Step.ConfigHeader {
        return b.addConfigHeader(.{ .include_path = "caml/m.h" }, .{
            .ARCH_SIXTYFOUR = @intFromBool(self.profile.pointer_bytes == 8),
            .SIZEOF_INT = 4,
            .SIZEOF_LONG = 8,
            .SIZEOF_PTR = self.profile.pointer_bytes,
            .SIZEOF_SHORT = 2,
            .SIZEOF_LONGLONG = 8,
            .HEADER_RESERVED_BITS = 0,
            .FLAT_FLOAT_ARRAY = @intFromBool(self.profile.flat_float_array),
            .NO_NAKED_POINTERS = 1,
            .CAML_SAFE_STRING = 1,
        });
    }

    pub fn systemHeader(self: Config, b: *Build) *Build.Step.ConfigHeader {
        return b.addConfigHeader(.{ .include_path = "caml/s.h" }, .{
            .OCAML_OS_TYPE = self.profile.os_type,
            .POSIX_SIGNALS = 1,
            .SUPPORT_DYNAMIC_LINKING = 1,
            .HAS_FULL_THREAD_VARIABLES = 1,
            .HAS_C99_FLOAT_OPS = 1,
            .HAS_WORKING_FMA = 1,
            .HAS_WORKING_ROUND = 1,
            .HAS_GETENTROPY = 1,
            .HAS_GETRUSAGE = 1,
            .HAS_TIMES = 1,
            .HAS_SYS_MMAN_H = 1,
            .HAS_LINUX_FUTEX_H = 1,
            .HAS_POSIX_MONOTONIC_CLOCK = 1,
            .HAVE_MAX_ALIGN_T = 1,
        });
    }

    pub fn cppHeaders(self: Config, b: *Build) [2]Build.LazyPath {
        const machine = self.machineHeader(b);
        const system = self.systemHeader(b);
        return .{
            machine.getOutputDir().path(b, "caml"),
            system.getOutputDir().path(b, "caml"),
        };
    }

    pub fn addCompilerSubstitutions(self: Config, b: *Build, run: *Build.Step.Run) void {
        for (compiler_values) |entry| {
            run.addArg(b.fmt("{s}={s}", .{ entry.key, entry.value }));
        }
        run.addArg(b.fmt("ocaml_bindir={s}", .{self.install_bin}));
        run.addArg(b.fmt("TARGET_BINDIR={s}", .{self.install_bin}));
        run.addArg(b.fmt("host={s}", .{self.profile.host_triple}));
        run.addArg(b.fmt("target={s}", .{self.profile.host_triple}));
        run.addArg(b.fmt("target_os_type={s}", .{self.profile.os_type}));
        run.addArg(b.fmt("flat_float_array={s}", .{boolean(self.profile.flat_float_array)}));
        run.addArg(b.fmt("align_double={s}", .{boolean(self.profile.align_double)}));
        run.addArg(b.fmt("align_int64={s}", .{boolean(self.profile.align_int64)}));
    }

    fn boolean(value: bool) []const u8 {
        return if (value) "true" else "false";
    }
};

pub const Value = struct {
    key: []const u8,
    value: []const u8,
};

/// Reviewed OCaml 5.5.1 config.generated.ml.in substitutions for this profile.
pub const compiler_values = [_]Value{
    .{ .key = "configure_input", .value = "Generated from config.generated.ml.in" },
    .{ .key = "QS", .value = "" },
    .{ .key = "ccomp_type", .value = "cc" },
    .{ .key = "CC", .value = "zig cc" },
    .{ .key = "ocaml_cc_vendor", .value = "clang" },
    .{ .key = "outputobj", .value = "-o " },
    .{ .key = "cc_has_debug_prefix_map", .value = "true" },
    .{ .key = "ocaml_cv_prog_as_debug_prefix_map", .value = "false" },
    .{ .key = "as_is_cc", .value = "true" },
    .{ .key = "bytecode_cflags", .value = "-std=gnu11 -fwrapv" },
    .{ .key = "bytecode_cppflags", .value = "" },
    .{ .key = "native_cflags", .value = "" },
    .{ .key = "native_cppflags", .value = "" },
    .{ .key = "zstd_libs", .value = "" },
    .{ .key = "cclibs", .value = "-lm -lpthread -ldl" },
    .{ .key = "native_ldflags", .value = "" },
    .{ .key = "with_nonexecstack_note", .value = "false" },
    .{ .key = "PACKLD", .value = "" },
    .{ .key = "rpath", .value = "" },
    .{ .key = "mksharedlibrpath", .value = "" },
    .{ .key = "AR", .value = "zig ar" },
    .{ .key = "supports_shared_libraries", .value = "false" },
    .{ .key = "natdynlink", .value = "false" },
    .{ .key = "mkdll_exp", .value = "" },
    .{ .key = "mkexe_exp", .value = "" },
    .{ .key = "mkmaindll_exp", .value = "" },
    .{ .key = "flambda", .value = "false" },
    .{ .key = "flambda_invariants", .value = "false" },
    .{ .key = "cmm_invariants", .value = "false" },
    .{ .key = "codegen_invariants", .value = "false" },
    .{ .key = "windows_unicode", .value = "0" },
    .{ .key = "function_sections", .value = "false" },
    .{ .key = "afl", .value = "false" },
    .{ .key = "bytecode_runtime_id", .value = "" },
    .{ .key = "native_runtime_id", .value = "" },
    .{ .key = "native_compiler", .value = "false" },
    .{ .key = "arch", .value = "none" },
    .{ .key = "model", .value = "default" },
    .{ .key = "system", .value = "linux" },
    .{ .key = "AS", .value = "zig cc" },
    .{ .key = "asm_cfi_supported", .value = "false" },
    .{ .key = "asm_size_type_directives", .value = "false" },
    .{ .key = "asm_dwarf_version", .value = "None" },
    .{ .key = "frame_pointers", .value = "false" },
    .{ .key = "reserved_header_bits", .value = "0" },
    .{ .key = "EXEEXT", .value = "" },
    .{ .key = "OBJEXT", .value = "o" },
    .{ .key = "S", .value = "s" },
    .{ .key = "libext", .value = "a" },
    .{ .key = "SO", .value = "so" },
    .{ .key = "systhread_support", .value = "true" },
    .{ .key = "flexdll_dir", .value = "" },
    .{ .key = "ar_supports_response_files", .value = "true" },
    .{ .key = "tsan", .value = "false" },
    .{ .key = "shebangscripts", .value = "true" },
    .{ .key = "suffixing", .value = "false" },
    .{ .key = "launch_method_target", .value = "sh" },
    .{ .key = "runtime_search_target", .value = "disable" },
};

test "bootstrap profile admits only native x86_64 Linux GNU" {
    const machine = @import("builtin").target;
    if (machine.cpu.arch != .x86_64 or machine.os.tag != .linux or machine.abi != .gnu) return;

    var config: Config = .{
        .build = machine,
        .host = machine,
        .target = machine,
        .profile = .{},
        .install_bin = "bin",
        .install_library = "lib/ocaml",
    };
    try std.testing.expect(config.supported());
    try std.testing.expect(config.profile.flat_float_array);
    try std.testing.expect(!config.profile.align_double and !config.profile.align_int64);

    config.target.abi = .musl;
    try std.testing.expect(!config.supported());
    config.target = machine;
    config.profile.align_double = true;
    try std.testing.expect(!config.supported());
}
