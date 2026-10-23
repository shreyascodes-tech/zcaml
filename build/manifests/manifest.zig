//! Build plan for a single OCaml source release.
//!
//! Generated from the upstream Makefiles / .depend files by `zig build generate`
//! (see `build/tools/gen_manifests.zig`) and checked in as `vX_Y_Z.zon`. The build
//! itself never runs `make`; everything it needs to know about the source tree is here.
const std = @import("std");

version: Version,
features: Features,
runtime: Runtime,
stdlib: Stdlib,
compiler: Compiler,
lex: Lex,
otherlibs: Otherlibs,

pub const Version = struct {
    string: []const u8,
    major: u32,
    minor: u32,
    patchlevel: u32,
    release_number: ?u32,
    dev: bool,
    extra: []const u8,
    extra_prefix: []const u8,
    /// `major * 10000 + minor * 100 + patchlevel`
    number: u32,
    magic: ?Magic,

    pub fn semVer(self: Version) std.SemanticVersion {
        return .{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patchlevel,
            .pre = if (self.extra.len > 0) self.extra else null,
        };
    }
};

pub const Magic = struct {
    prefix: []const u8,
    version: []const u8,
    exec_format: []const u8,
    exec_length: usize,
    numbers: MagicNumbers,
};

pub const MagicNumbers = struct {
    exec: []const u8,
    cmi: []const u8,
    cmo: []const u8,
    cma: []const u8,
    cmx_clambda: []const u8,
    cmxa_clambda: []const u8,
    ast_impl: []const u8,
    ast_intf: []const u8,
    cmxs: []const u8,
    cmt: []const u8,
    linear: []const u8,
};

/// Capabilities of the source tree. This is the only place where release differences
/// are encoded; the build never compares version numbers.
pub const Features = struct {
    /// Relocatable installs (5.5+): relative stdlib dir, `-set-runtime-default`,
    /// `-launch-method` / `-runtime-search` linker flags.
    relocatable: bool,
    /// Format of the bytecode launcher header in the stdlib dir.
    header_format: HeaderFormat,
    /// `prims.c` uses the `gen_primsc` layout (5.2+).
    gen_primsc: bool,
    /// `prims.c` must define `caml_byte_program_mode` (5.5+).
    byte_program_mode: bool,
    /// `utils/config.common.ml.in` is a template (else a plain `.ml`).
    config_common_template: bool,
    /// `utils/config.generated.ml.in` exists (else `utils/config.mlp`).
    config_generated_template: bool,
    /// `bytecomp/byterntm.mll` exists.
    byterntm: bool,
    /// `ocamlyacc` understands `--strict`.
    yacc_strict: bool,
    /// Bytecode C stub libraries carry a `byt` suffix (`libunixbyt.a`, `dllunixbyt.so`).
    byt_stub_suffix: bool,
    /// Dynlink is built standalone from `dynlink_config.ml.in` (else it packs
    /// `Dynlink_compilerlibs`, see `otherlibs.dynlink_pack`).
    dynlink_standalone: bool,
    /// Runtime supports zstd-compressed marshaling (`runtime/zstd.c`).
    zstd: bool,
};

pub const HeaderFormat = enum {
    /// `camlheader`, `camlheaderd`, ... (5.0 / 5.1)
    camlheader,
    /// `runtime-launch-info` with launch method + bindir prefix (5.2 - 5.4)
    launch_info_5_2,
    /// `runtime-launch-info` without bindir (5.5+)
    launch_info_5_5,
};

/// OCaml native-code backend architectures (`asmcomp/<arch>`).
pub const Arch = enum {
    amd64,
    i386,
    arm64,
    arm,
    power,
    riscv,
    s390x,
};

/// Where the source of a compilation unit comes from.
pub const Src = union(enum) {
    /// Path relative to the OCaml source root.
    upstream: []const u8,
    /// `asmcomp/<target arch>/<name>`
    arch: []const u8,
    /// Module-alias-expanded copy of the upstream file at this path.
    expanded: []const u8,
    /// A file generated during the build.
    gen: Gen,
};

/// Files generated during the build that compilation units may refer to.
pub const Gen = enum {
    config_main_ml,
    config_boot_ml,
    domainstate_ml,
    domainstate_mli,
    runtimedef_ml,
    camlinternalMenhirLib_mli,
    parser_ml,
    parser_mli,
    parsing_lexer_ml,
    byterntm_ml,
    opcodes_ml,
    opcodes_mli,
    opnames_ml,
    emit_ml,
    lex_parser_ml,
    lex_parser_mli,
    lex_lexer_ml,
    stdlib_sys_ml,
};

/// Where a unit's artifacts go in the install layout.
pub const Dest = enum {
    /// Not installed (only linked into archives / programs).
    none,
    /// The library's own install directory (`stdlib`, `compiler-libs`, ...).
    lib,
    /// `lib/ocaml/profiling`
    profiling,
};

pub const Unit = struct {
    /// Unique key within a plan, e.g. `utils/misc`, `toplevel/byte/topeval`.
    key: []const u8,
    /// Output file stem, e.g. `misc` -> `misc.cmi` / `misc.cmo`.
    name: []const u8,
    src: Src,
    /// Extra compiler flags for this unit.
    flags: []const []const u8 = &.{},
    /// Only build for these target architectures (empty = all).
    archs: []const Arch = &.{},
    dest: Dest = .none,

    pub fn enabledFor(self: Unit, arch: ?Arch) bool {
        if (self.archs.len == 0) return true;
        const a = arch orelse return false;
        return std.mem.indexOfScalar(Arch, self.archs, a) != null;
    }
};

/// A set of compilation units.
pub const Plan = struct {
    /// Units producing a `.cmi`, layered so every unit only depends on earlier waves.
    /// `intf` units compile an `.mli`; `impl` units are `.ml` files without an
    /// interface and produce both `.cmi` and `.cmo`.
    cmi_waves: []const []const WaveUnit,
    /// Implementations whose interface was compiled in `cmi_waves`.
    cmo_units: []const Unit,
};

pub const WaveUnit = struct {
    kind: enum { intf, impl },
    unit: Unit,
};

pub const Runtime = struct {
    common_c_sources: []const []const u8,
    unix_c_sources: []const []const u8,
    win32_c_sources: []const []const u8,
    bytecode_only_c_sources: []const []const u8,
    native_only_c_sources: []const []const u8,
    comprmarsh_c_sources: []const []const u8,
    ocamlyacc_c_sources: []const []const u8,
};

pub const Stdlib = struct {
    compflags: []const []const u8,
    plan: Plan,
    /// Keys of the units archived into `stdlib.cma`, in link order.
    cma: []const []const u8,
    /// Modules kept by `expunge` when building the toplevel.
    pervasives: []const []const u8,
};

pub const Compiler = struct {
    compflags: []const []const u8,
    plan: Plan,
    /// Keys of the units in each `compilerlibs/*.cma`, in link order.
    ocamlcommon: []const []const u8,
    ocamlbytecomp: []const []const u8,
    ocamlmiddleend: []const []const u8,
    ocamloptcomp: []const []const u8,
    ocamltoplevel: []const []const u8,
    /// Keys of the units linked into each standalone tool, in link order.
    ocamlprof: []const []const u8,
    ocamlcp: []const []const u8,
    ocamloptp: []const []const u8,
    ocamlmklib: []const []const u8,
    ocamlmktop: []const []const u8,
};

pub const Lex = struct {
    plan: Plan,
    /// Keys of the units linked into `ocamllex`, in link order.
    ocamllex: []const []const u8,
};

pub const Otherlibs = struct {
    compflags: []const []const u8,
    systhreads_compflags: []const []const u8,
    unix_common_c_sources: []const []const u8,
    unix_unix_c_sources: []const []const u8,
    unix_win32_c_sources: []const []const u8,
    unix_headers: []const []const u8,
    str_c_sources: []const []const u8,
    runtime_events_c_sources: []const []const u8,
    runtime_events_headers: []const []const u8,
    threads_header: []const u8,
    /// Compiler modules packed into `Dynlink_compilerlibs` (only when
    /// `!features.dynlink_standalone`).
    dynlink_pack: Plan,
};
