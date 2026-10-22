const std = @import("std");

version_string: []const u8,
major: u32,
minor: u32,
patchlevel: u32,
release_number: ?u32,
dev_version: bool,
extra: []const u8,
extra_prefix: []const u8,
version_number: u32,
magic_prefix: ?[]const u8,
magic_version: ?[]const u8,
exec_format: ?[]const u8,
exec_magic_length: ?usize,
magic_numbers: ?MagicNumbers,

// Runtime & ocamlyacc C sources
runtime_common_c_sources: []const []const u8,
runtime_unix_c_sources: []const []const u8,
runtime_win32_c_sources: []const []const u8,
runtime_bytecode_only_c_sources: []const []const u8,
runtime_native_only_c_sources: []const []const u8,
comprmarsh_c_sources: []const []const u8,
ocamlyacc_c_sources: []const []const u8,

// Standard library
stdlib_compflags: []const []const u8,
stdlib_units: []const StdlibUnit,
stdlib_cmi_waves: []const []const []const u8,
has_std_exit_mli: bool,
std_exit_compflags: []const []const u8,
pervasives_modules: []const []const u8,

// Compiler & tools
compiler_compflags: []const []const u8,
compiler_cmi_waves: []const []const CompilerCmiUnit,
compiler_cmo_units: []const CompilerCmoUnit,
ocamlcommon_cmos: []const []const u8,
ocamlbytecomp_cmos: []const []const u8,
ocamlmiddleend_cmos: []const []const u8,
ocamloptcomp_cmos: []const []const u8,
ocamltoplevel_cmos: []const []const u8,
ocamlprof_cmos: []const []const u8,
ocamlcp_cmos: []const []const u8,
ocamloptp_cmos: []const []const u8,
ocamlmklib_cmos: []const []const u8,
ocamlmktop_cmos: []const []const u8,

// ocamllex
lex_cmi_waves: []const []const CompilerCmiUnit,
lex_cmo_units: []const CompilerCmoUnit,
ocamllex_cmos: []const []const u8,

// Otherlibs
otherlibs_compflags: []const []const u8,
systhreads_compflags: []const []const u8,
unix_common_c_sources: []const []const u8,
unix_unix_c_sources: []const []const u8,
unix_win32_c_sources: []const []const u8,
str_c_sources: []const []const u8,
runtime_events_c_sources: []const []const u8,
unix_headers: []const []const u8,
runtime_events_headers: []const []const u8,
threads_header: []const u8,
dynlink_pack_cmi_waves: []const []const []const u8,
dynlink_pack_units: []const DynlinkPackUnit,

pub fn semVer(self: @This()) std.SemanticVersion {
    return .{
        .major = self.major,
        .minor = self.minor,
        .patch = self.patchlevel,
    };
}

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

pub const StdlibUnit = struct {
    basename: []const u8,
    module_name: []const u8,
    has_mli: bool,
    expand_mli_aliases: bool,
    expand_ml_aliases: bool,
    cmi_flags: []const []const u8 = &.{},
    cmo_flags: []const []const u8 = &.{},
};

pub const CompilerCmiUnit = struct {
    /// Unit key (e.g. "utils/misc", "parsing/asttypes", "asmcomp/arch")
    key: []const u8,
    /// Output .cmi basename (e.g. "misc.cmi", "asttypes.cmi", "arch.cmi")
    cmi_name: []const u8,
    /// Output .cmo basename when `is_ml_without_mli` is true
    cmo_name: []const u8 = "",
    /// Source path relative to OCaml root, or "@gen/<name>", or "@arch/<name>"
    src_path: []const u8,
    /// True if no .mli exists and compiling `src_path` (.ml) produces both .cmo and .cmi
    is_ml_without_mli: bool = false,
    /// True if this unit only applies to x86/amd64 targets (`asmcomp/x86_*`)
    only_intel: bool = false,
};

pub const CompilerCmoUnit = struct {
    /// Unit key (e.g. "utils/misc", "asmcomp/proc", "toplevel/byte/topeval")
    key: []const u8,
    /// Output .cmo basename (e.g. "misc.cmo", "proc.cmo", "topeval.cmo")
    cmo_name: []const u8,
    /// Source .ml path relative to OCaml root, or "@gen/<name>", or "@arch/<name>"
    src_path: []const u8,
    /// Extra flags for this specific unit (e.g. `-no-alias-deps` for `tools/ocamltex`)
    extra_flags: []const []const u8 = &.{},
    /// True if this unit only applies to x86/amd64 targets (`asmcomp/x86_*`)
    only_intel: bool = false,
};

pub const DynlinkPackUnit = struct {
    /// Module stem (e.g. "misc", "config", "asttypes")
    stem: []const u8,
    /// Source .mli path relative to OCaml root, or "@gen/<name>"
    mli_src: []const u8,
    /// Source .ml path relative to OCaml root, or "@gen/<name>"
    ml_src: []const u8,
    /// True if `ml_src` is actually a `.mli` file compiled with `-impl`
    ml_is_intf: bool = false,
};
