const std = @import("std");
const Context = @import("context.zig");
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
///     ctx,
///     input_file_path,
///     "some-file-name",
///     &.{
///         .once("some-pattern", .str("some-replacement")),
///         .all("another-pattern", .str("some-replacement")),
///     },
/// );
/// ```
pub fn replaceAll(
    ctx: *Context,
    input_file_path: LazyPath,
    output_file_basename: []const u8,
    substitutions: []const Substitution,
) LazyPath {
    const b = ctx.b;
    const substitutions_json = std.json.Stringify.valueAlloc(b.allocator, substitutions, .{}) catch @panic("OOM");

    return ctx.tool("tools/replace-all.zig").cmd(b)
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

/// A Zig program from ./tools compiled for the host, to be run at build time.
///
/// Example:
/// ```zig
/// const gen = tools.ZigTool.init(b, "my-zig-exe", b.path("tools/my-tool.zig"));
/// const output_file = gen.cmd(b)
///     .inFile(some_input_file)
///     .outFile("output.txt")
///     .arg("some-arg")
///     .popOutFile();
/// ```
/// Prefer `ctx.tool("tools/my-tool.zig")`, which caches the compiled tool.
pub const ZigTool = struct {
    exe: *std.Build.Step.Compile,

    pub fn init(b: *std.Build, name: []const u8, src_path: LazyPath) ZigTool {
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

    pub fn cmd(self: *const ZigTool, b: *std.Build) *Cmd {
        return Cmd.init(b, self.exe);
    }
};

/// Fluent wrapper around `std.Build.Step.Run` for any compiled executable.
/// Arguments are appended in call order.
pub const Cmd = struct {
    b: *std.Build,
    run: *std.Build.Step.Run,
    outfiles: std.ArrayList(LazyPath),

    pub fn init(b: *std.Build, exe: *std.Build.Step.Compile) *Cmd {
        const self = b.allocator.create(Cmd) catch @panic("OOM");
        self.* = .{
            .b = b,
            .run = b.addRunArtifact(exe),
            .outfiles = .empty,
        };
        return self;
    }

    pub fn arg(self: *Cmd, s: []const u8) *Cmd {
        self.run.addArg(s);
        return self;
    }

    pub fn args(self: *Cmd, a: []const []const u8) *Cmd {
        self.run.addArgs(a);
        return self;
    }

    pub fn inFile(self: *Cmd, s: LazyPath) *Cmd {
        self.run.addFileArg(s);
        return self;
    }

    pub fn outFile(self: *Cmd, s: []const u8) *Cmd {
        const outfile = self.run.addOutputFileArg(s);
        self.outfiles.append(self.b.allocator, outfile) catch @panic("OOM");
        return self;
    }

    pub fn cwd(self: *Cmd, s: LazyPath) *Cmd {
        self.run.setCwd(s);
        return self;
    }

    pub fn dependOn(self: *Cmd, step: *std.Build.Step) *Cmd {
        self.run.step.dependOn(step);
        return self;
    }

    pub fn popOutFile(self: *Cmd) LazyPath {
        return self.outfiles.pop().?;
    }

    pub fn outFileAt(self: *Cmd, i: usize) LazyPath {
        return self.outfiles.items[i];
    }

    pub fn stdout(self: *Cmd) LazyPath {
        return self.run.captureStdOut(.{});
    }
};
