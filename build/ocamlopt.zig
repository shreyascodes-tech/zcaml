//! Running the freshly bootstrapped native compiler on the build machine.
const std = @import("std");
const Ocamlc = @import("ocamlc.zig");
const LazyPath = std.Build.LazyPath;
const Ocamlopt = @This();

b: *std.Build,
ocamlrun: *std.Build.Step.Compile,
exe: LazyPath,
stdlib_dir: ?LazyPath,

pub const Options = Ocamlc.Options;

pub fn cmd(self: Ocamlopt, opts: Options) *std.Build.Step.Run {
    const run = self.b.addRunArtifact(self.ocamlrun);
    // Build steps must find the Zig used by this build, even when it was invoked
    // by absolute path and is not otherwise on PATH.
    run.setEnvironmentVariable("PATH", self.b.fmt("{s}{s}{s}", .{
        std.fs.path.dirname(self.b.graph.zig_exe).?,
        if (self.b.graph.host.result.os.tag == .windows) ";" else ":",
        run.getEnvMap().get("PATH") orelse "",
    }));
    run.addFileArg(self.exe);
    run.addArg("-nostdlib");
    if (self.stdlib_dir) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
    for (opts.includes) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
    run.addArgs(opts.flags);
    return run;
}

pub const Impl = struct {
    cmx: LazyPath,
    obj: LazyPath,
};

/// Each compilation must see the `.cmx`s of its implementation dependencies.
pub fn impl(self: Ocamlopt, src: LazyPath, name: []const u8, cmi: LazyPath, opts: Options) Impl {
    const run = self.cmd(opts);
    run.addArg("-cmi-file");
    run.addFileArg(cmi);
    run.addArg("-o");
    const cmx = run.addOutputFileArg(self.b.fmt("{s}.cmx", .{name}));
    run.addArgs(&.{ "-c", "-impl" });
    run.addFileArg(src);
    return .{ .cmx = cmx, .obj = cmx.dirname().path(self.b, self.b.fmt("{s}.o", .{name})) };
}

pub const Archive = struct {
    cmxa: LazyPath,
    lib: LazyPath,
};

/// `ocamlopt -a` also archives the objects adjacent to the input `.cmx`s.
pub fn archive(self: Ocamlopt, name: []const u8, objs: []const LazyPath, opts: Options) Archive {
    const run = self.cmd(opts);
    run.addArgs(&.{ "-a", "-o" });
    const cmxa = run.addOutputFileArg(self.b.fmt("{s}.cmxa", .{name}));
    for (objs) |obj| run.addFileArg(obj);
    return .{ .cmxa = cmxa, .lib = cmxa.dirname().path(self.b, self.b.fmt("{s}.a", .{name})) };
}

pub fn shared(self: Ocamlopt, name: []const u8, archive_file: LazyPath, opts: Options) LazyPath {
    const run = self.cmd(opts);
    run.addArgs(&.{ "-shared", "-linkall", "-o" });
    const out = run.addOutputFileArg(self.b.fmt("{s}.cmxs", .{name}));
    run.addFileArg(archive_file);
    return out;
}
