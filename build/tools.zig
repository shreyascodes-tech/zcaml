const std = @import("std");
const utils = @import("tools/utils.zig");

pub const InputFile = utils.InputFile;
pub const OutputFile = utils.OutputFile;
pub const InputDir = utils.InputDir;
pub const OutputDir = utils.OutputDir;

pub const Command = union(enum) {
    gen_runtime: @import("tools/gen_runtime.zig"),
    gen_manifests: @import("tools/gen_manifests.zig"),
    gen_stdlib_sources: @import("tools/gen_stdlib_sources.zig"),
    gen_compiler_sources: @import("tools/gen_compiler_sources.zig"),
    cat: @import("tools/cat.zig"),
    gen_flexlink_sources: @import("tools/gen_flexlink_sources.zig"),
    verify_toolchains: @import("tools/verify_toolchains.zig"),
};

pub const Tag = std.meta.Tag(Command);

pub fn Args(comptime tag: Tag) type {
    return @FieldType(Command, @tagName(tag));
}

/// Add a step running a tool. Returns `args` with its output fields
/// (`OutputFile` / `OutputDir`) resolved to lazy paths, and the step:
/// `const gen, _ = Tools.run(b, .gen_runtime, .{ ... });`
pub fn run(b: *std.Build, comptime tag: Tag, args: Args(tag)) struct { Args(tag), *std.Build.Step.Run } {
    var filled = args;
    const step = b.addRunArtifact(toolsExe(b));
    step.addArg(@tagName(tag));
    inline for (comptime std.meta.fieldNames(Args(tag))) |field| {
        addNamedFieldArg(b, step, field, &@field(filled, field));
    }
    return .{ filled, step };
}

var tools_exe: ?*std.Build.Step.Compile = null;

fn toolsExe(b: *std.Build) *std.Build.Step.Compile {
    if (tools_exe) |exe| return exe;
    const exe = b.addExecutable(.{
        .name = "tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/tools.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    tools_exe = exe;
    return exe;
}

fn addNamedFieldArg(
    b: *std.Build,
    run_tool: *std.Build.Step.Run,
    comptime field_name: []const u8,
    field_ptr: anytype,
) void {
    const FieldType = @typeInfo(@TypeOf(field_ptr)).pointer.child;

    if (@typeInfo(FieldType) == .optional) {
        if (field_ptr.*) |*inner| {
            addNamedFieldArg(b, run_tool, field_name, inner);
        }
        return;
    }

    if (comptime isListSlice(FieldType)) {
        for (field_ptr.*) |*elem| {
            addSingleNamedArg(b, run_tool, field_name, elem);
        }
        return;
    }

    addSingleNamedArg(b, run_tool, field_name, field_ptr);
}

fn addSingleNamedArg(
    b: *std.Build,
    run_tool: *std.Build.Step.Run,
    comptime field_name: []const u8,
    val_ptr: anytype,
) void {
    const ValType = @typeInfo(@TypeOf(val_ptr)).pointer.child;
    const flag = "--" ++ field_name;

    if (ValType == InputFile) {
        run_tool.addArg(flag);
        run_tool.addFileArg(val_ptr.lazy);
    } else if (ValType == OutputFile) {
        run_tool.addArg(flag);
        val_ptr.lazy.path = run_tool.addOutputFileArg(val_ptr.lazy.basename);
    } else if (ValType == InputDir) {
        run_tool.addArg(flag);
        run_tool.addDirectoryArg(val_ptr.lazy);
    } else if (ValType == OutputDir) {
        run_tool.addArg(flag);
        val_ptr.lazy.path = run_tool.addOutputDirectoryArg(val_ptr.lazy.basename);
    } else if (ValType == []const u8 or ValType == []u8) {
        run_tool.addArgs(&.{ flag, val_ptr.* });
    } else if (ValType == bool) {
        if (val_ptr.*) {
            run_tool.addArg(flag);
        }
    } else if (@typeInfo(ValType) == .int) {
        run_tool.addArgs(&.{ flag, b.fmt("{d}", .{val_ptr.*}) });
    } else if (@typeInfo(ValType) == .@"enum") {
        run_tool.addArgs(&.{ flag, @tagName(val_ptr.*) });
    } else {
        @compileError("Unsupported tool field type: " ++ @typeName(ValType) ++ " for field '" ++ field_name ++ "'");
    }
}

pub fn main(init: std.process.Init) !void {
    utils.mode = .run;

    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    const command_name = args.next() orelse return printUsage(gpa, null);
    const command_tag = std.meta.stringToEnum(Tag, command_name) orelse return printUsage(gpa, command_name);

    var parser = ArgParser{ .args_it = &args };
    @setEvalBranchQuota(100_000);
    switch (command_tag) {
        inline else => |tag| {
            const T = @FieldType(Command, @tagName(tag));
            const TFieldEnum = std.meta.FieldEnum(T);

            var result: T = undefined;
            var found: std.EnumSet(TFieldEnum) = .empty;
            while (parser.next()) |named| {
                const field = std.meta.stringToEnum(TFieldEnum, named.name) orelse {
                    std.log.warn("unknown option: '{s}' for command '{s}'", .{ named.name, command_name });
                    continue;
                };

                switch (field) {
                    inline else => |f| {
                        const FieldType = @FieldType(T, @tagName(f));
                        if (found.contains(field) and !comptime isListSlice(FieldType)) {
                            std.log.warn("option '{s}' specified multiple times, ignoring", .{named.name});
                            continue;
                        }

                        try assignFieldValue(arena, FieldType, &@field(result, @tagName(f)), named.value, found.contains(field));
                        found.insert(field);
                    },
                }
            }

            var missing_required = false;
            var not_found_it = found.complement().iterator();
            const struct_info = @typeInfo(T).@"struct";
            while (not_found_it.next()) |field| {
                switch (field) {
                    inline else => |f| {
                        const idx = @backingInt(f);
                        const FieldType = struct_info.field_types[idx];

                        if (struct_info.field_attrs[idx].defaultValue(FieldType)) |default_val| {
                            @field(result, @tagName(f)) = default_val;
                        } else if (@typeInfo(FieldType) == .optional) {
                            @field(result, @tagName(f)) = null;
                        } else if (comptime isListSlice(FieldType)) {
                            @field(result, @tagName(f)) = &.{};
                        } else {
                            std.log.err("missing required option '--{t}' for command '{s}'", .{ f, command_name });
                            missing_required = true;
                        }
                    },
                }
            }

            if (missing_required) std.process.exit(1);
            try result.run(init);
        },
    }
}

fn isListSlice(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return false;
    return @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice;
}

const ArgParser = struct {
    pending: ?[]const u8 = null,
    args_it: *std.process.Args.Iterator,

    const Named = struct {
        name: []const u8,
        value: ?[]const u8,
    };

    pub fn next(self: *ArgParser) ?Named {
        while (true) {
            const arg = self.args_it.next() orelse {
                if (self.pending) |name| {
                    self.pending = null;
                    return .{ .name = name, .value = null };
                }
                return null;
            };

            if (self.pending) |name| {
                if (std.mem.startsWith(u8, arg, "--")) {
                    self.pending = arg[2..];
                    return .{ .name = name, .value = null };
                }
                self.pending = null;
                return .{ .name = name, .value = arg };
            }

            if (std.mem.startsWith(u8, arg, "--")) {
                self.pending = arg[2..];
                continue;
            }
            std.debug.panic("unexpected positional argument '{s}'", .{arg});
        }
    }
};

fn assignFieldValue(
    arena: std.mem.Allocator,
    comptime FieldType: type,
    field_ptr: *FieldType,
    raw_value: ?[]const u8,
    already_found: bool,
) !void {
    if (@typeInfo(FieldType) == .optional) {
        const Child = @typeInfo(FieldType).optional.child;
        field_ptr.* = try parseSingleValue(Child, raw_value);
        return;
    }

    if (comptime isListSlice(FieldType)) {
        const Elem = @typeInfo(FieldType).pointer.child;
        const parsed = try parseSingleValue(Elem, raw_value);
        const existing = if (already_found) field_ptr.* else &.{};
        const new_slice = try arena.alloc(Elem, existing.len + 1);
        @memcpy(new_slice[0..existing.len], existing);
        new_slice[existing.len] = parsed;
        field_ptr.* = new_slice;
        return;
    }

    field_ptr.* = try parseSingleValue(FieldType, raw_value);
}

fn parseSingleValue(comptime ValType: type, raw: ?[]const u8) !ValType {
    if (ValType == InputFile or ValType == OutputFile or ValType == InputDir or ValType == OutputDir) {
        return .{ .cli = raw orelse return error.MissingOptionValue };
    } else if (ValType == []const u8) {
        return raw orelse return error.MissingOptionValue;
    } else if (ValType == bool) {
        const val = raw orelse return true;
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) return false;
        return error.InvalidBooleanValue;
    } else if (@typeInfo(ValType) == .int) {
        return std.fmt.parseInt(ValType, raw orelse return error.MissingOptionValue, 0);
    } else if (@typeInfo(ValType) == .@"enum") {
        return std.meta.stringToEnum(ValType, raw orelse return error.MissingOptionValue) orelse error.InvalidEnumValue;
    } else {
        @compileError("Unsupported tool value type: " ++ @typeName(ValType));
    }
}

fn printUsage(gpa: std.mem.Allocator, command: ?[]const u8) noreturn {
    std.log.err(
        \\Usage: tools <command> [args...]
        \\
        \\Available commands:
        \\  {s}
    , .{std.mem.join(gpa, " ", std.meta.fieldNames(Tag)) catch @panic("OOM")});

    if (command) |c| std.log.err("Unknown command: '{s}'", .{c});
    std.process.exit(1);
}
