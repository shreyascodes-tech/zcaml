const std = @import("std");

pub var mode: enum { build, run } = .build;

pub const InputFile = union(enum) {
    lazy: std.Build.LazyPath,
    cli: []const u8,

    pub fn of(lp: std.Build.LazyPath) InputFile {
        std.debug.assert(mode == .build); // must not be used in the run handlers of the commands
        return .{ .lazy = lp };
    }

    pub fn path(self: InputFile) []const u8 {
        std.debug.assert(mode == .run); // must only be used in the run handlers of the commands
        return self.cli;
    }
};

pub const OutputFile = union(enum) {
    lazy: struct {
        basename: []const u8,
        path: std.Build.LazyPath,
    },
    cli: []const u8,

    pub fn of(basename: []const u8) OutputFile {
        std.debug.assert(mode == .build); // must not be used in the run handlers of the commands
        return .{
            .lazy = .{
                .basename = basename,
                // safety: the path is set by the run handler. any use of this path before calling run is illegal
                .path = undefined,
            },
        };
    }

    pub fn lazyPath(self: OutputFile) std.Build.LazyPath {
        std.debug.assert(mode == .build); // must not be used in the run handlers of the commands
        return self.lazy.path;
    }

    pub fn path(self: OutputFile) []const u8 {
        std.debug.assert(mode == .run); // must only be used in the run handlers of the commands
        return self.cli;
    }
};
