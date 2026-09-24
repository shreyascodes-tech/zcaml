const std = @import("std");
const LazyPath = std.Build.LazyPath;

pub const Substitution = struct {
    /// the literal pattern to be replaced
    literal_pattern: []const u8,
    /// the replacement value
    replacement: Value,
    /// the maximum number of occurances to replace
    occurances: u32 = std.math.maxInt(u32),

    pub fn all(literal_pattern: []const u8, replacement: Value) Substitution {
        return .{
            .literal_pattern = literal_pattern,
            .replacement = replacement,
        };
    }

    pub fn once(literal_pattern: []const u8, replacement: Value) Substitution {
        return .{
            .literal_pattern = literal_pattern,
            .replacement = replacement,
            .occurances = 1,
        };
    }
};

/// Replaces occurances of patterns with the given values in a file.
/// Example:
/// ```zig
/// tools.replaceAll(
///     builder,
///     input_file_path,
///     "some-file-name",
///     &.{
///         .once("some-pattern", .lit("some-replacement")),
///         .all("another-pattern", .lit("some-replacement")),
///     },
/// );
/// ```
pub fn replaceAll(
    builder: *std.Build,
    input_file_path: LazyPath,
    output_file_basename: []const u8,
    substitutions: []const Substitution,
) LazyPath {
    const replace_exe = struct {
        var exe: ?*std.Build.Step.Compile = null;
        fn get(b: *std.Build) *std.Build.Step.Compile {
            if (exe) |e| return e;
            exe = b.addExecutable(.{
                .name = "replace-all",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/replace-all.zig"),
                    .target = b.graph.host,
                    .optimize = .ReleaseSafe,
                }),
            });
            return exe.?;
        }
    };

    const run_replace_exe = builder.addRunArtifact(replace_exe.get(builder));
    run_replace_exe.addFileArg(input_file_path);

    const output_file_path = run_replace_exe.addOutputFileArg(output_file_basename);

    const substitutions_json = std.json.Stringify.valueAlloc(builder.allocator, substitutions, .{}) catch @panic("oom");
    run_replace_exe.addArg(substitutions_json);

    return output_file_path;
}

/// Converts an autoconf undef config header into a C header.
/// Example:
/// ```zig
/// configHeader(
///     builder,
///     input_file,
///     &.{
///         .{ "FOO", .lit("bar") }, // outputs a literal #define FOO bar
///         .{ "BAZ", .str("qux") }, // outputs a string #define BAZ "qux"
///         .{ "QUUX", .flagOrNull(true) }, // outputs a boolean #define QUUX 1
///         .{ "QUUX", .flagOrNull(false) }, // outputs #undef QUUX
///         .{ "QUUX", .int(42) }, // outputs a number #define QUUX 42
///     },
/// }
/// ```
pub fn configHeader(
    builder: *std.Build,
    input_file: LazyPath,
    values: []const struct { []const u8, Value },
) LazyPath {
    const header = builder.addConfigHeader(.{
        .style = .{ .autoconf_undef = input_file },
    }, .{});
    for (values) |value| {
        switch (value.@"1") {
            .literal => |literal| header.addIdent(value.@"0", literal),
            inline else => |v| header.addValue(value.@"0", @TypeOf(v), v),
        }
    }
    return header.getOutputFile();
}

pub const Value = union(enum) {
    literal: []const u8,
    string: []const u8,
    boolean: bool,
    boolean_or_null: ?bool,
    integer: i64,

    pub fn lit(value: []const u8) Value {
        return .{ .literal = value };
    }

    pub fn str(value: []const u8) Value {
        return .{ .string = value };
    }

    pub fn flag(value: bool) Value {
        return .{ .boolean = value };
    }

    pub fn flagOrNull(value: bool) Value {
        return .{ .boolean_or_null = if (value) true else null };
    }

    pub fn int(value: i64) Value {
        return .{ .integer = value };
    }

    pub fn jsonStringify(self: Value, jws: *std.json.Stringify) !void {
        try switch (self) {
            .literal => {
                try jws.beginWriteRaw();
                defer jws.endWriteRaw();

                try jws.writer.writeAll(self.literal);
            },
            .string => |s| jws.write(s),
            .boolean => jws.write(if (self.boolean) "true" else "false"),
            .boolean_or_null => |b| jws.write(if (b orelse false) "true" else "false"),
            .integer => jws.print("{d}", .{self.integer}),
        };
    }
};
