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
/// Examp le:
/// ```zig
/// tools.replaceAll(
///     builder,
///     input_file_path,
///     "some-file-name",
///     &.{
///         .once("some-pattern", .str("some-replacement")),
///         .all("another-pattern", .str("some-replacement")),
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
        var exe: ?RunZigFile = null;
        fn get(b: *std.Build) *const RunZigFile {
            if (exe) |e| return e;
            exe = RunZigFile.init(b, "replace-all", b.path("tools/replace-all.zig"));
            return exe.?;
        }
    };

    const substitutions_json = std.json.Stringify.valueAlloc(builder.allocator, substitutions, .{}) catch @panic("oom");

    return replace_exe.get(builder).run(builder)
        .inFile(input_file_path)
        .outFile(output_file_basename)
        .arg(substitutions_json)
        .popOutFile();
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
            .integer => jws.print("\"{d}\"", .{self.integer}),
        };
    }
};

/// A convenience wrapper for creating a Zig executable and running it.
///
/// Example:
/// ```zig
/// const run_zig = tools.RunZigFile.init(b, "my-zig-exe", my_zig_file);
/// const run = run_zig.run(b)
///     .inFile(some_input_file)
///     .outFile("output.txt")
///     .str("some-arg");
/// const output_file = run.outFileAt(0);
/// ```
pub fn addZigRun(b: *std.Build, name: []const u8, src_path: LazyPath) RunZigFile {
    return RunZigFile.init(b, name, src_path);
}

pub const RunZigFile = struct {
    exe: *std.Build.Step.Compile,

    pub fn init(b: *std.Build, name: []const u8, src_path: LazyPath) RunZigFile {
        const module = b.createModule(.{
            .root_source_file = src_path,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        });

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = module,
        });

        return .{ .exe = exe };
    }

    pub fn run(self: *const RunZigFile, b: *std.Build) *Run {
        return Run.init(b, self.exe);
    }

    pub const Run = struct {
        b: *std.Build,
        run: *std.Build.Step.Run,
        outfiles: std.ArrayList(LazyPath),

        pub fn init(b: *std.Build, exe: *std.Build.Step.Compile) *Run {
            const self = b.allocator.create(Run) catch @panic("OOM");
            self.* = .{
                .b = b,
                .run = b.addRunArtifact(exe),
                .outfiles = .empty,
            };
            return self;
        }

        pub fn arg(self: *Run, s: []const u8) *Run {
            self.run.addArg(s);
            return self;
        }

        pub fn args(self: *Run, a: []const []const u8) *Run {
            self.run.addArgs(a);
            return self;
        }

        pub fn inFile(self: *Run, s: LazyPath) *Run {
            self.run.addFileArg(s);
            return self;
        }

        pub fn outFile(self: *Run, s: []const u8) *Run {
            const outfile = self.run.addOutputFileArg(s);
            self.outfiles.append(self.b.allocator, outfile) catch @panic("OOM");
            return self;
        }

        pub fn popOutFile(self: *Run) LazyPath {
            return self.outfiles.pop().?;
        }

        pub fn outFileAt(self: *Run, i: usize) LazyPath {
            return self.outfiles.items[i];
        }

        pub fn stdout(self: *Run) LazyPath {
            return self.run.captureStdOut(.{});
        }
    };
};
