const std = @import("std");

pub fn ocamlTriple(allocator: std.mem.Allocator, target: std.Target) []const u8 {
    const architecture = switch (target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm, .thumb => "arm",
        .riscv64 => "riscv64",
        .powerpc64le => "powerpc64le",
        .powerpc64 => "powerpc64",
        .powerpc => "powerpc",
        .s390x => "s390x",
        else => "unknown",
    };
    const operating_system = switch (target.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        else => "unknown",
    };
    const abi = if (target.isGnuLibC())
        "gnu"
    else if (target.isMuslLibC())
        "musl"
    else
        @tagName(target.abi);

    return std.fmt.allocPrint(allocator, "{s}-pc-{s}-{s}", .{
        architecture,
        operating_system,
        abi,
    }) catch @panic("out of memory");
}
