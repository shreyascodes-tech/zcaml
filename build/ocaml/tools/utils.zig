//! Build-time and run-time file and directory wrappers for generator tools.
//!
//! Types here operate in two modes governed by `mode`:
//! - `.build`: used inside `build.zig` to configure tool execution steps (`.of(...)`, `.lazyPath()`).
//! - `.run`: used inside tool `run(...)` methods to access CLI arguments and perform I/O (`.path()`, `.open(...)`, etc.).

const std = @import("std");

pub var mode: enum { build, run } = .build;

pub const InputFile = union(enum) {
    lazy: std.Build.LazyPath,
    cli: []const u8,

    pub fn of(lp: std.Build.LazyPath) InputFile {
        std.debug.assert(mode == .build);
        return .{ .lazy = lp };
    }

    pub fn path(self: InputFile) []const u8 {
        std.debug.assert(mode == .run);
        return self.cli;
    }

    pub fn readAll(self: InputFile, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, self.path(), gpa, .unlimited);
    }
};

pub const OutputFile = union(enum) {
    lazy: struct {
        basename: []const u8,
        path: std.Build.LazyPath,
    },
    cli: []const u8,

    pub fn of(basename: []const u8) OutputFile {
        std.debug.assert(mode == .build);
        return .{
            .lazy = .{
                .basename = basename,
                .path = undefined,
            },
        };
    }

    pub fn lazyPath(self: OutputFile) std.Build.LazyPath {
        std.debug.assert(mode == .build);
        return self.lazy.path;
    }

    pub fn path(self: OutputFile) []const u8 {
        std.debug.assert(mode == .run);
        return self.cli;
    }

    pub fn writer(self: OutputFile, io: std.Io, buffer: []u8) !std.Io.File.Writer {
        const file = try std.Io.Dir.cwd().createFile(io, self.path(), .{});
        return file.writer(io, buffer);
    }

    pub fn writeAll(self: OutputFile, io: std.Io, data: []const u8) !void {
        return std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = self.path(),
            .data = data,
        });
    }
};

pub const InputDir = union(enum) {
    lazy: std.Build.LazyPath,
    cli: []const u8,

    pub fn of(lp: std.Build.LazyPath) InputDir {
        std.debug.assert(mode == .build);
        return .{ .lazy = lp };
    }

    pub fn path(self: InputDir) []const u8 {
        std.debug.assert(mode == .run);
        return self.cli;
    }

    pub fn open(self: InputDir, io: std.Io, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(io, self.path(), options);
    }
};

pub const OutputDir = union(enum) {
    lazy: struct {
        basename: []const u8,
        path: std.Build.LazyPath,
    },
    cli: []const u8,

    pub fn of(basename: []const u8) OutputDir {
        std.debug.assert(mode == .build);
        return .{
            .lazy = .{
                .basename = basename,
                .path = undefined,
            },
        };
    }

    pub fn lazyPath(self: OutputDir) std.Build.LazyPath {
        std.debug.assert(mode == .build);
        return self.lazy.path;
    }

    pub fn path(self: OutputDir) []const u8 {
        std.debug.assert(mode == .run);
        return self.cli;
    }

    pub fn open(self: OutputDir, io: std.Io, options: std.Io.Dir.CreateDirPathOpenOptions) !std.Io.Dir {
        return std.Io.Dir.cwd().createDirPathOpen(io, self.path(), options);
    }
};

/// Patch upstream sources: replace the one occurrence of `needle` in `haystack`.
pub fn replaceOnce(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, haystack, needle) orelse {
        std.log.err("patch does not apply, expected:\n{s}", .{needle});
        return error.PatchDoesNotApply;
    };
    if (std.mem.indexOfPos(u8, haystack, idx + 1, needle) != null) return error.PatchIsAmbiguous;
    return std.mem.concat(arena, u8, &.{ haystack[0..idx], replacement, haystack[idx + needle.len ..] });
}
