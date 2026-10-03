const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 11) return error.InvalidArguments;

    // runtime compiler name interface-source implementation-source output-dir mode
    // own-cmi-or-"-" interface-flags -- implementation-flags -- include-dirs...
    // The own CMI is an input file, never an implicit first include directory.
    const runtime = args[1];
    const compiler = args[2];
    const module_name = args[3];
    const interface_source = args[4];
    const implementation_source = args[5];
    const dir = args[6];
    const mode = args[7];
    const own_interface = args[8];
    const is_interface = std.mem.eql(u8, mode, "interface");
    const is_implementation = std.mem.eql(u8, mode, "implementation");
    const is_standalone = std.mem.eql(u8, mode, "standalone");
    if (!is_interface and !is_implementation and !is_standalone) {
        return error.InvalidArguments;
    }
    const has_own_interface = !std.mem.eql(u8, own_interface, "-");
    if (is_implementation != has_own_interface) {
        return error.InvalidArguments;
    }
    try Io.Dir.cwd().createDirPath(init.io, dir);

    var position: usize = 9;
    const intf_flags = try flags(args, &position);
    const impl_flags = try flags(args, &position);
    const deps = args[position..];

    if (std.mem.eql(u8, mode, "implementation")) {
        const output = try std.fmt.allocPrint(gpa, "{s}/{s}.cmi", .{ dir, module_name });
        try Io.Dir.cwd().copyFile(own_interface, Io.Dir.cwd(), output, init.io, .{});

        // ocamlc only reuses a prebuilt .cmi when the .mli sits next to the
        // .ml it compiles. Put both sources into this isolated output directory.
        const ml_name = try std.fmt.allocPrint(gpa, "{s}.ml", .{module_name});
        const mli_name = try std.fmt.allocPrint(gpa, "{s}.mli", .{module_name});
        const local_ml = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, ml_name });
        const local_mli = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, mli_name });

        try Io.Dir.cwd().copyFile(implementation_source, Io.Dir.cwd(), local_ml, init.io, .{});
        try Io.Dir.cwd().copyFile(interface_source, Io.Dir.cwd(), local_mli, init.io, .{});
    } else if (std.mem.eql(u8, mode, "standalone")) {
        const local_ml = try std.fmt.allocPrint(gpa, "{s}/{s}.ml", .{ dir, module_name });
        try Io.Dir.cwd().copyFile(implementation_source, Io.Dir.cwd(), local_ml, init.io, .{});
    }

    const CompileInput = struct {
        source: []const u8,
        ext: []const u8,
        extra: []const []const u8,
    };
    for ([_]CompileInput{
        .{ .source = interface_source, .ext = ".cmi", .extra = intf_flags },
        .{ .source = implementation_source, .ext = ".cmo", .extra = impl_flags },
    }) |entry| {
        if (std.mem.eql(u8, mode, "interface") and std.mem.eql(u8, entry.ext, ".cmo")) {
            break;
        }
        if ((std.mem.eql(u8, mode, "implementation") or std.mem.eql(u8, mode, "standalone")) and
            std.mem.eql(u8, entry.ext, ".cmi"))
        {
            continue;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(gpa, &.{
            runtime,      compiler,
            "-nostdlib",  "-strict-sequence",
            "-w",         "+a-4-9-41-42-44-45-48",
            "-principal",
        });
        try argv.appendSlice(gpa, entry.extra);
        try argv.appendSlice(gpa, &.{ "-I", dir });

        for (deps) |dep| {
            try argv.appendSlice(gpa, &.{ "-I", dep });
        }

        const output = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, module_name, entry.ext });
        const source = if (std.mem.eql(u8, mode, "standalone"))
            try std.fmt.allocPrint(gpa, "{s}/{s}.ml", .{ dir, module_name })
        else if (std.mem.eql(u8, mode, "implementation"))
            try std.fmt.allocPrint(gpa, "{s}/{s}.ml", .{ dir, module_name })
        else
            entry.source;

        try argv.appendSlice(gpa, &.{ "-c", source, "-o", output });
        var child = try std.process.spawn(init.io, .{
            .argv = argv.items,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const result = try child.wait(init.io);
        if (result != .exited or result.exited != 0) return error.CompilerFailed;
    }
}

fn flags(args: []const []const u8, position: *usize) ![]const []const u8 {
    const start = position.*;
    while (position.* < args.len and !std.mem.eql(u8, args[position.*], "--")) {
        position.* += 1;
    }

    if (position.* == args.len) return error.InvalidArguments;
    const result = args[start..position.*];
    position.* += 1;
    return result;
}
