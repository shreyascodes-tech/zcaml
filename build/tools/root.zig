const std = @import("std");
const utils = @import("utils.zig");
pub const InputFile = utils.InputFile;
pub const OutputFile = utils.OutputFile;
pub const InputDir = utils.InputDir;
pub const OutputDir = utils.OutputDir;

const Self = @This();

pub const Command = union(enum) {
    hello: @import("hello.zig"),
    gen_runtime: @import("gen_runtime.zig"),

    pub fn run(self: *Command, b: *std.Build) *std.Build.Step.Run {
        const tool_exe = (struct {
            var tool_exe: ?*std.Build.Step.Compile = null;

            fn get(builder: *std.Build) *std.Build.Step.Compile {
                if (tool_exe) |exe| return exe;

                const exe = builder.addExecutable(.{
                    .name = "tools",
                    .root_module = builder.createModule(.{
                        .root_source_file = builder.path("build/tools/root.zig"),
                        .target = builder.graph.host,
                        .optimize = .Debug,
                    }),
                });

                tool_exe = exe;
                return exe;
            }
        }).get(b);
        const run_tool = b.addRunArtifact(tool_exe);

        const selected_tool_tag = @as(std.meta.Tag(Command), self.*);
        switch (selected_tool_tag) {
            inline else => |tag| {
                const command_name = @tagName(tag);
                run_tool.addArg(command_name);

                const tool_args = &@field(self, command_name);
                const T = std.meta.fieldInfo(Command, tag).type;

                inline for (comptime std.meta.fieldNames(T)) |field| {
                    if (comptime !std.mem.eql(u8, field, "--")) {
                        addNamedFieldArg(b, run_tool, field, &@field(tool_args, field));
                    }
                }

                if (@hasField(T, "--")) {
                    const rest_ptr = &@field(tool_args, "--");
                    const RestType = @TypeOf(rest_ptr.*);
                    const items = if (comptime isArrayList(RestType)) rest_ptr.items else rest_ptr.*;
                    if (items.len > 0) {
                        run_tool.addArg("--");
                        for (items) |*item| {
                            addPositionalArg(b, run_tool, item);
                        }
                    }
                }
            },
        }

        return run_tool;
    }
};

fn isListSlice(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return false;
    return @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice;
}

fn isArrayList(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasField(T, "items") or !@hasField(T, "capacity")) return false;
    const ItemsType = @FieldType(T, "items");
    if (@typeInfo(ItemsType) != .pointer or @typeInfo(ItemsType).pointer.size != .slice) return false;
    const Elem = @typeInfo(ItemsType).pointer.child;
    return T == std.ArrayList(Elem);
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

    if (comptime isArrayList(FieldType)) {
        for (field_ptr.items) |*elem| {
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
    } else if (@typeInfo(ValType) == .int or @typeInfo(ValType) == .float) {
        run_tool.addArgs(&.{ flag, b.fmt("{d}", .{val_ptr.*}) });
    } else if (@typeInfo(ValType) == .@"enum") {
        run_tool.addArgs(&.{ flag, @tagName(val_ptr.*) });
    } else {
        @compileError("Unsupported tool field type: " ++ @typeName(ValType) ++ " for field '" ++ field_name ++ "'");
    }
}

fn addPositionalArg(
    b: *std.Build,
    run_tool: *std.Build.Step.Run,
    val_ptr: anytype,
) void {
    const ValType = @typeInfo(@TypeOf(val_ptr)).pointer.child;

    if (ValType == InputFile) {
        run_tool.addFileArg(val_ptr.lazy);
    } else if (ValType == OutputFile) {
        val_ptr.lazy.path = run_tool.addOutputFileArg(val_ptr.lazy.basename);
    } else if (ValType == InputDir) {
        run_tool.addDirectoryArg(val_ptr.lazy);
    } else if (ValType == OutputDir) {
        val_ptr.lazy.path = run_tool.addOutputDirectoryArg(val_ptr.lazy.basename);
    } else if (ValType == []const u8 or ValType == []u8) {
        run_tool.addArg(val_ptr.*);
    } else if (@typeInfo(ValType) == .int or @typeInfo(ValType) == .float) {
        run_tool.addArg(b.fmt("{d}", .{val_ptr.*}));
    } else if (@typeInfo(ValType) == .@"enum") {
        run_tool.addArg(@tagName(val_ptr.*));
    } else {
        @compileError("Unsupported positional element type: " ++ @typeName(ValType));
    }
}

pub fn main(init: std.process.Init) !void {
    utils.mode = .run;

    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // skip the program name

    const command_name = args.next() orelse return printUsage(gpa, null);
    const command_tag = std.meta.stringToEnum(
        std.meta.Tag(Command),
        command_name,
    ) orelse return printUsage(gpa, command_name);

    var parser = ArgParser{ .args_it = &args };
    @setEvalBranchQuota(100_000);
    switch (command_tag) {
        inline else => |tag| {
            const T = std.meta.fieldInfo(Command, tag).type;
            const TFieldEnum = std.meta.FieldEnum(T);

            var result: T = undefined;
            var found: std.EnumSet(TFieldEnum) = .empty;
            while (true) {
                switch (parser.next() orelse break) {
                    .named => |named| {
                        const field = std.meta.stringToEnum(TFieldEnum, named.name) orelse {
                            std.log.warn("unknown option: '{s}' for command '{s}'", .{ named.name, command_name });
                            continue;
                        };

                        switch (field) {
                            inline else => |f| {
                                const FieldType = std.meta.fieldInfo(T, f).type;
                                const is_multi = comptime (isListSlice(FieldType) or isArrayList(FieldType));

                                if (found.contains(field) and !is_multi) {
                                    std.log.warn("option '{s}' specified multiple times, ignoring", .{named.name});
                                    continue;
                                }

                                try assignFieldValue(arena, FieldType, &@field(result, @tagName(f)), named.value, found.contains(field));
                                found.insert(field);
                            },
                        }
                    },
                    .positional => |positional| {
                        if (@hasField(T, "--")) {
                            const RestField = @field(TFieldEnum, "--");
                            const RestType = std.meta.fieldInfo(T, RestField).type;
                            try assignFieldValue(arena, RestType, &@field(result, "--"), positional, found.contains(RestField));
                            found.insert(RestField);
                        } else {
                            std.debug.panic("positional argument '{s}' not allowed", .{positional});
                        }
                    },
                }
            }

            var missing_required = false;
            const not_found = found.complement();
            var not_found_it = not_found.iterator();
            while (not_found_it.next()) |field| {
                switch (field) {
                    inline else => |f| {
                        const field_info = std.meta.fieldInfo(T, f);
                        const FieldType = field_info.type;

                        if (field_info.defaultValue()) |default_val| {
                            @field(result, @tagName(f)) = default_val;
                        } else if (@typeInfo(FieldType) == .optional) {
                            @field(result, @tagName(f)) = null;
                        } else if (comptime isListSlice(FieldType)) {
                            @field(result, @tagName(f)) = &.{};
                        } else if (comptime isArrayList(FieldType)) {
                            @field(result, @tagName(f)) = .empty;
                        } else {
                            std.log.err("missing required option '--{t}' for command '{s}'", .{ f, command_name });
                            missing_required = true;
                        }
                    },
                }
            }

            if (missing_required) {
                std.process.exit(1);
            }

            try result.run(init);
        },
    }
}

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

    if (comptime isArrayList(FieldType)) {
        const Elem = @typeInfo(@FieldType(FieldType, "items")).pointer.child;
        const parsed = try parseSingleValue(Elem, raw_value);
        if (!already_found) {
            field_ptr.* = .empty;
        }
        try field_ptr.append(arena, parsed);
        return;
    }

    field_ptr.* = try parseSingleValue(FieldType, raw_value);
}

fn parseSingleValue(comptime ValType: type, raw: ?[]const u8) !ValType {
    if (ValType == InputFile) {
        return .{ .cli = raw orelse return error.MissingOptionValue };
    } else if (ValType == OutputFile) {
        return .{ .cli = raw orelse return error.MissingOptionValue };
    } else if (ValType == InputDir) {
        return .{ .cli = raw orelse return error.MissingOptionValue };
    } else if (ValType == OutputDir) {
        return .{ .cli = raw orelse return error.MissingOptionValue };
    } else if (ValType == []const u8) {
        return raw orelse return error.MissingOptionValue;
    } else if (ValType == bool) {
        const val = raw orelse return true;
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) return false;
        return error.InvalidBooleanValue;
    } else if (@typeInfo(ValType) == .int) {
        const val = raw orelse return error.MissingOptionValue;
        return std.fmt.parseInt(ValType, val, 0);
    } else if (@typeInfo(ValType) == .float) {
        const val = raw orelse return error.MissingOptionValue;
        return std.fmt.parseFloat(ValType, val);
    } else if (@typeInfo(ValType) == .@"enum") {
        const val = raw orelse return error.MissingOptionValue;
        return std.meta.stringToEnum(ValType, val) orelse error.InvalidEnumValue;
    } else {
        @compileError("Unsupported tool value type: " ++ @typeName(ValType));
    }
}

fn printUsage(gpa: std.mem.Allocator, command: ?[]const u8) noreturn {
    std.log.err(
        \\Usage: zig run build/tools/tools.zig <command> [args...]
        \\
        \\Available commands:
        \\  {s}
    , .{std.mem.join(gpa, " ", std.meta.fieldNames(std.meta.Tag(Command))) catch @panic("OOM")});

    if (command) |c| {
        std.log.err("Unknown command: '{s}'", .{c});
    }
    std.process.exit(1);
}

const ArgParser = struct {
    state: State = .arg_or_rest,
    args_it: *std.process.Args.Iterator,

    pub fn next(self: *ArgParser) ?Result {
        while (true) {
            const arg = self.args_it.next() orelse {
                if (self.state == .arg) {
                    const name = self.state.arg;
                    self.state = .arg_or_rest;
                    return Result{ .named = .{ .name = name, .value = null } };
                }

                return null;
            };

            switch (self.state) {
                .rest => {
                    return Result{ .positional = arg };
                },
                .arg_or_rest => {
                    if (arg.len < 2) {
                        return Result{ .positional = arg };
                    }
                    if (std.mem.eql(u8, arg, "--")) {
                        self.state = .rest;
                        continue;
                    }
                    if (std.mem.startsWith(u8, arg, "--")) {
                        self.state = .{ .arg = arg[2..] };
                        continue;
                    }

                    return Result{ .positional = arg };
                },
                .arg => |name| {
                    if (arg.len < 2) {
                        self.state = .arg_or_rest;
                        return Result{ .named = .{ .name = name, .value = arg } };
                    }

                    if (std.mem.eql(u8, arg, "--")) {
                        self.state = .rest;
                        return Result{ .named = .{ .name = name, .value = null } };
                    }

                    if (std.mem.startsWith(u8, arg, "--")) {
                        self.state = .{ .arg = arg[2..] };
                        return Result{ .named = .{ .name = name, .value = null } };
                    }

                    self.state = .arg_or_rest;
                    return Result{ .named = .{ .name = name, .value = arg } };
                },
            }
        }
    }

    const Result = union(enum) {
        named: struct {
            name: []const u8,
            value: ?[]const u8,
        },
        positional: []const u8,
    };

    const State = union(enum) {
        rest,
        arg_or_rest,
        arg: []const u8,
    };
};
