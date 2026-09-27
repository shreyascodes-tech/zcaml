/// Source paths are relative to the OCaml source root. A missing source may
/// be produced by a matching generation rule.
ocaml_version: []const u8,
release_number: u32,
magic_prefix: []const u8,
magic_version: []const u8,
exec_format: []const u8,
source_hash: []const u8,
source_groups: []const SourceGroup,
backend_sources: []const BackendSources,
generated_files: []const GeneratedFile,
dependencies: []const Dependency,

/// Source groups linked into the bootstrap bytecode interpreter.
pub fn isBytecodeRuntimeGroup(name: []const u8) bool {
    const std = @import("std");
    return std.mem.eql(u8, name, "runtime_common") or
        std.mem.eql(u8, name, "runtime_bytecode_only") or
        std.mem.eql(u8, name, "runtime_platform_unix");
}

/// Ordered upstream source membership, including .mli files. Some source
/// groups overlap (e.g. ocamloptcomp contains ocamlmiddleend).
pub const SourceGroup = struct {
    name: []const u8,
    files: []const []const u8,
};

pub const BackendSources = struct {
    arch: []const u8,
    /// Files selected for the asmcomp/arch, proc, emit, etc. modules.
    files: []const []const u8,
    /// Runtime assembly candidates; the OS profile chooses between variants.
    runtime_assembly: []const []const u8,
};

pub const GeneratedFile = struct {
    output: []const u8,
    /// A named transform implemented by build_support or tools, not a shell recipe.
    transform: []const u8,
    inputs: []const []const u8,
    /// The build selects exactly one platform-specific addition to inputs.
    platform_inputs: []const PlatformInputs = &.{},
    /// For a backend-specific rule, one entry is recorded per backend.
    arch: ?[]const u8 = null,
    /// For a platform-specific output, one entry is recorded per platform.
    platform: ?[]const u8 = null,
};

pub const PlatformInputs = struct {
    platform: []const u8,
    files: []const []const u8,
};

/// One normalized Make dependency rule. The prerequisite and output paths
/// are relative to the OCaml source root even for stdlib/.depend.
pub const Dependency = struct {
    output: []const u8,
    prerequisites: []const []const u8,
    arch: ?[]const u8 = null,
};
