const std = @import("std");
const utils = @import("utils.zig");
const InputFile = utils.InputFile;
const OutputFile = utils.OutputFile;

const Self = @This();

pub const Command = union(enum) {
    hello: @import("hello.zig"),

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

                const tool_args = @field(self, command_name);
                const T = std.meta.fieldInfo(Command, tag).type;

                inline for (comptime std.meta.fieldNames(T)) |field| {
                    // todo handle file types
                    run_tool.addArgs(&.{
                        b.fmt("--{s}", .{field}),
                        @field(tool_args, field),
                    });
                }
            },
        }

        return run_tool;
    }
};

pub fn main(init: std.process.Init) !void {
    utils.mode = .run;

    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // skip the program name

    const command_name = args.next() orelse return printUsage(gpa, null);
    const command_tag = std.meta.stringToEnum(
        std.meta.Tag(Command),
        command_name,
    ) orelse return printUsage(gpa, command_name);

    var parser = ArgParser{ .args_it = &args };
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

                        if (found.contains(field)) {
                            // todo handle list of values
                            std.log.warn("option '{s}' specified multiple times, ignoring", .{named.name});
                            continue;
                        }

                        switch (field) {
                            inline else => |f| {
                                // todo handle file types
                                @field(result, @tagName(f)) = named.value orelse continue;
                                found.insert(field);
                            },
                        }
                    },
                    .positional => |positional| {
                        // todo handle an arg called @"--" with an array list or a slice of values in the struct
                        std.debug.panic("positional argument '{s}' not allowed", .{positional});
                    },
                }
            }

            var found_it = found.iterator();
            while (found_it.next()) |field| {
                switch (field) {
                    inline else => |f| {
                        std.log.info("found field: '{t}' = {s}", .{ f, @field(result, @tagName(f)) });
                    },
                }
            }

            const not_found = found.complement();
            var not_found_it = not_found.iterator();
            while (not_found_it.next()) |field| {
                std.log.info("not found field: '{t}'", .{field});
            }
        },
    }

    while (parser.next()) |result| {
        switch (result) {
            .named => |named| {
                std.log.info("named: '{s}' = '{?s}'", .{ named.name, named.value });
            },
            .positional => |positional| {
                std.log.info("positional: '{s}'", .{positional});
            },
        }
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
