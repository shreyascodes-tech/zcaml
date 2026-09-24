//! State required for building ocaml.
//! Only util methods. No build logic happens here.

const std = @import("std");

const State = @This();

const LazyPath = std.Build.LazyPath;

b: *std.Build,

ocaml_dep: *std.Build.Dependency,

/// the output target of exes final ocaml will produce
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
/// the step that triggerd this ocaml build
/// can be used to attach file installations etc to it
step: *std.Build.Step,

pub fn ocamlRel(self: *const State, sub: []const u8) LazyPath {
    return self.ocaml_dep.path(sub);
}


}
