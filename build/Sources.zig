//! Source lists extracted from the OCaml tree's Makefiles and `.depend`
//! files, persisted as `build/gen/sources.g.zon` so normal builds don't
//! interpret make. Written by `ocaml-gen sources`, read by the build script;
//! compiled into both, so must not depend on `std.Build`.
//!
//! Lists keep Makefile order, which is link order for OCaml objects.

const std = @import("std");

const Sources = @This();

/// `build.zig.zon`'s hash for the `ocaml` dependency these came from.
ocaml_hash: []const u8,
runtime: Runtime,
stdlib: Stdlib,
compilerlibs: Compilerlibs,
programs: Programs,
/// `ocamlyacc_OTHER_MODULES`, without `yacc/` or `.c`.
yacc: []const []const u8,
depend: Depend,

pub const Runtime = struct {
    /// `runtime_COMMON_C_SOURCES` minus `$(UNIX_OR_WIN32)`. Basenames without `.c`.
    common: []const []const u8,
    platform: struct { unix: []const u8, win32: []const u8 },
    bytecode_only: []const []const u8,
    /// Minus `$(TSAN_NATIVE_RUNTIME_C_SOURCES)`.
    native_only: []const []const u8,
    /// Not a Makefile variable: written inline into `libcamlrund_OBJECTS`.
    debug_only: []const []const u8 = &.{"instrtrace"},
};

pub const Stdlib = struct {
    /// `STDLIB_MODULE_BASENAMES`.
    basenames: []const []const u8,
    /// The same with `PREFIX_MODULE` applied (`stdlib__Arg`): the compiled
    /// object names.
    modules: []const []const u8,
};

/// Paths relative to the tree root, `.mli`/`.ml`/`.mll`/`.mly` interleaved
/// as in the Makefile.
pub const Compilerlibs = struct {
    ocamlcommon: []const []const u8,
    ocamlbytecomp: []const []const u8,
    ocamloptcomp: []const []const u8,
    ocamltoplevel: []const []const u8,
};

pub const Programs = struct {
    ocamlc: []const []const u8,
    ocamlopt: []const []const u8,
    ocaml: []const []const u8,
    ocamllex: []const []const u8,
};

/// `.cm{i,o,x}` rules only.
pub const Depend = struct {
    compiler: []const Rule,
    /// Paths relative to `stdlib/`.
    stdlib: []const Rule,
};

pub const Rule = struct {
    target: []const u8,
    deps: []const []const u8,
};

pub const Backend = enum { bytecode, native };
pub const Platform = enum { unix, win32 };

/// `runtime/<name>.c` for one runtime.
pub fn runtimeFiles(
    s: Sources,
    gpa: std.mem.Allocator,
    backend: Backend,
    platform: Platform,
) error{OutOfMemory}![]const []const u8 {
    const specific = switch (backend) {
        .bytecode => s.runtime.bytecode_only,
        .native => s.runtime.native_only,
    };
    const platform_file = switch (platform) {
        .unix => s.runtime.platform.unix,
        .win32 => s.runtime.platform.win32,
    };
    var out = try std.ArrayList([]const u8).initCapacity(gpa, s.runtime.common.len + 1 + specific.len);
    for (s.runtime.common) |n| out.appendAssumeCapacity(try runtimePath(gpa, n));
    out.appendAssumeCapacity(try runtimePath(gpa, platform_file));
    for (specific) |n| out.appendAssumeCapacity(try runtimePath(gpa, n));
    return out.toOwnedSlice(gpa);
}

pub fn runtimeDebugFiles(s: Sources, gpa: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    const out = try gpa.alloc([]const u8, s.runtime.debug_only.len);
    for (out, s.runtime.debug_only) |*o, n| o.* = try runtimePath(gpa, n);
    return out;
}

pub fn parse(gpa: std.mem.Allocator, text: [:0]const u8, diag: *std.zon.parse.Diagnostics) error{ OutOfMemory, ParseZon }!Sources {
    return std.zon.parse.fromSliceAlloc(Sources, gpa, text, diag, .{});
}

fn runtimePath(gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(gpa, "runtime/{s}.c", .{name});
}
