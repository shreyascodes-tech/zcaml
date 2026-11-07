//! dune's entry point, linked ahead of the OCaml runtime's `main` (`runtime/main.c`,
//! a member of `libasmrun.a` that the linker then leaves out). A lock directory
//! package's cross build runs `cross.zig`; anything else is dune.
//!
//! No Zig start code: this sets up `std.process.Init` itself, like `start.zig`.
const std = @import("std");
const builtin = @import("builtin");
const cross = @import("cross.zig");

const windows = builtin.os.tag == .windows;
const Char = if (windows) u16 else u8;
const CArgv = [*:null]?[*:0]const Char;

comptime {
    @export(&main, .{ .name = if (windows) "wmain" else "main" });
}

fn main(argc: c_int, argv: CArgv, envp: CArgv) callconv(.c) c_int {
    if (isCrossBuild(argc, argv)) crossMain(argc, argv, envp);

    var c = argc;
    var v = argv;
    if (windows) caml_expand_command_line(&c, &v); // wildcards and `@file`s
    caml_main(v);
    caml_do_exit(0);
}

/// `dune build` or `dune exec`, in a cross context's package build.
fn isCrossBuild(argc: c_int, argv: CArgv) bool {
    inline for (cross.markers) |name| if (getenv(name) == null) return false;
    if (argc < 2) return false;
    const command = std.mem.span(argv[1].?);
    inline for (cross.commands) |c| if (std.mem.eql(Char, command, literal(c))) return true;
    return false;
}

fn getenv(comptime name: [:0]const u8) ?[*:0]const Char {
    return if (windows) _wgetenv(literal(name)) else std.c.getenv(name.ptr);
}

fn literal(comptime s: [:0]const u8) [:0]const Char {
    return if (windows) std.unicode.utf8ToUtf16LeStringLiteral(s) else s;
}

fn crossMain(argc: c_int, argv: CArgv, envp: CArgv) noreturn {
    const args: std.process.Args = .{ .vector = if (windows)
        std.os.windows.peb().ProcessParameters.CommandLine.slice()
    else
        @ptrCast(argv[0..@intCast(argc)]) };
    const environ: std.process.Environ = .{ .block = if (windows) .global else .{ .slice = std.mem.span(envp) } };

    const gpa = std.heap.c_allocator;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(args), .environ = environ });
    var environ_map = environ.createMap(gpa) catch std.process.fatal("out of memory", .{});

    cross.main(.{
        .minimal = .{ .args = args, .environ = environ },
        .arena = &arena,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    }) catch |err| std.process.fatal("{t}", .{err});
    std.process.exit(0);
}

extern fn caml_main(argv: CArgv) void;
extern fn caml_do_exit(code: c_int) noreturn;
extern fn caml_expand_command_line(argc: *c_int, argv: *CArgv) void;
extern "c" fn _wgetenv(name: [*:0]const u16) ?[*:0]const u16;
