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

_replace_exe: ?*std.Build.Step.Compile = null,

pub fn ocamlRel(self: *const State, sub: []const u8) LazyPath {
    return self.ocaml_dep.path(sub);
}

pub const Substitution = struct {
    /// the literal pattern to be replaced
    literal_pattern: []const u8,
    /// the replacement string
    replacement: []const u8,
    /// the maximum number of occurances to replace
    occurances: u32 = std.math.maxInt(u32),
};

/// replaces all occurences of `substitutions` in `input_file_path` and writes the result to `output_file_basename`
pub fn replaceAll(
    self: *State,
    input_file_path: LazyPath,
    output_file_basename: []const u8,
    substitutions: []const Substitution,
) LazyPath {
    const replace_exe = self._replace_exe orelse blk: {
        const replace_exe = self.b.addExecutable(.{
            .name = "replace-all",
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path("tools/replace-all.zig"),
                .target = self.b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });

        self._replace_exe = replace_exe;
        break :blk replace_exe;
    };

    const run_replace_exe = self.b.addRunArtifact(replace_exe);
    run_replace_exe.addFileArg(input_file_path);

    const output_file_path = run_replace_exe.addOutputFileArg(output_file_basename);

    const substitutions_json = std.json.Stringify.valueAlloc(self.b.allocator, substitutions, .{}) catch @panic("oom");
    run_replace_exe.addArg(substitutions_json);

    return output_file_path;
}
