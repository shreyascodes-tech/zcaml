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

    pub fn open(self: InputFile, io: std.Io, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
        return std.Io.Dir.cwd().openFile(io, self.path(), options);
    }

    pub fn reader(self: InputFile, io: std.Io, buffer: []u8) !std.Io.File.Reader {
        const file = try self.open(io, .{});
        return file.reader(io, buffer);
    }

    pub fn readAll(self: InputFile, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, self.path(), gpa, .unlimited);
    }

    pub fn readAllZ(self: InputFile, io: std.Io, gpa: std.mem.Allocator) ![:0]u8 {
        return std.Io.Dir.cwd().readFileAllocOptions(io, self.path(), gpa, .unlimited, .of(u8), 0);
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

    pub fn create(self: OutputFile, io: std.Io, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
        return std.Io.Dir.cwd().createFile(io, self.path(), flags);
    }

    pub fn writer(self: OutputFile, io: std.Io, buffer: []u8) !std.Io.File.Writer {
        const file = try self.create(io, .{});
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
