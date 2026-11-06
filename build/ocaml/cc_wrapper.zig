//! `zcaml-cc-<target>`: the C compiler of a toolchain (`ocamlc -config`'s `c_compiler`).
//!
//! Runs `zig cc` with the target's flags baked in, followed by its own arguments.
//! `c_compiler` has to be a single program: tools like dune split it into a program
//! and flags and don't always pass the flags (and pass them twice when they do), so
//! `zig cc -target ...` doesn't work there. The name is unique per target so the
//! wrappers of several toolchains can be on `PATH` at once.
//!
//! The `zig` run is `$ZIG` if set, otherwise `zig` from `PATH`.
//!
//! For macOS targets, it adds the macOS SDK's frameworks, headers (after Zig's own)
//! and libraries, which Zig doesn't ship, if there is one (`macosSdk`): Xcode's on
//! macOS, or one installed next to the toolchain (`scripts/add-macos-sdk.sh`).
//!
//! Compiles in a dune-configurator probe directory get a local zig cache there
//! (`isConfiguratorProbe`): the probe paths are random, so their entries in the
//! global cache could never be reused.
//!
//! It runs for every C compilation, so it is kept small: libc's `execvp` on POSIX,
//! `CreateProcessW` on Windows, and nothing of `std.Io`, panics or stack traces.
const std = @import("std");
const builtin = @import("builtin");
/// `args`: the target's `zig cc` flags. `macos_sdk`: whether the target is macOS.
const options = @import("options");

pub const panic = std.debug.no_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
    .allow_stack_tracing = false,
};

pub fn main(init: std.process.Init.Minimal) u8 {
    return if (builtin.os.tag == .windows) windows.run(init.args.vector) else posix.run(init.args.vector);
}

const posix = struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fgets(buf: [*]u8, len: c_int, stream: *anyopaque) ?[*:0]u8;
    extern "c" fn pclose(stream: *anyopaque) c_int;

    /// The target flags, NUL-terminated.
    const target_args = blk: {
        var args: [options.args.len][*:0]const u8 = undefined;
        for (&args, options.args) |*z, arg| z.* = std.fmt.comptimePrint("{s}", .{arg});
        const final = args;
        break :blk final;
    };

    fn run(args: []const [*:0]const u8) u8 {
        const zig = std.c.getenv("ZIG") orelse "zig";
        var cwd_buf: [4096]u8 = undefined;
        if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |cwd| {
            if (isConfiguratorProbe(u8, std.mem.span(@as([*:0]u8, @ptrCast(cwd)))))
                _ = setenv("ZIG_LOCAL_CACHE_DIR", ".zig-cache", 0);
        }

        var sdk_buf: [sdk_dirs.len][*:0]const u8 = undefined;
        const sdk_args: []const [*:0]const u8 = if (options.macos_sdk) sdkArgs(&sdk_buf) else &.{};

        // zig cc <target args> <SDK args> <our args, minus the program name>
        const ours = args[@min(args.len, 1)..];
        const len = 2 + target_args.len + sdk_args.len + ours.len;
        const ptr: [*]?[*:0]const u8 = @ptrCast(@alignCast(std.c.malloc((len + 1) * @sizeOf(?[*:0]const u8)) orelse return cannotRun(zig)));
        const argv = ptr[0..len :null];
        argv[0..2].* = .{ zig, "cc" };
        var i: usize = 2;
        for ([_][]const [*:0]const u8{ &target_args, sdk_args, ours }) |part| {
            @memcpy(argv[i..][0..part.len], part);
            i += part.len;
        }
        argv[len] = null;

        _ = execvp(zig, argv);
        return cannotRun(zig);
    }

    fn cannotRun(zig: [*:0]const u8) u8 {
        for ([_][]const u8{ "zcaml-cc: could not run ", std.mem.span(zig), "\n" }) |s| _ = std.c.write(2, s.ptr, s.len);
        return 127;
    }

    /// `sdk_dirs`' flags for the macOS SDK, if there is one.
    fn sdkArgs(buf: *[sdk_dirs.len][*:0]const u8) []const [*:0]const u8 {
        const root = macosSdk() orelse return &.{};
        for (buf, sdk_dirs) |*arg, dir| arg.* = concat(&.{ dir.flag, root, dir.path }) orelse return &.{};
        return buf;
    }

    /// `$ZCAML_MACOS_SDK`, or on macOS `$SDKROOT`; else the one installed with the
    /// toolchain; else on macOS Xcode's.
    fn macosSdk() ?[]const u8 {
        if (std.c.getenv("ZCAML_MACOS_SDK")) |sdk| return std.mem.span(sdk);
        if (builtin.os.tag == .macos) if (std.c.getenv("SDKROOT")) |sdk| return std.mem.span(sdk);
        if (installedSdk()) |sdk| return sdk;
        if (builtin.os.tag == .macos) return xcrunSdk();
        return null;
    }

    var path_buf: [4096]u8 = undefined;

    fn installedSdk() ?[]const u8 {
        const exe = selfExe() orelse return null;
        const bin = exe[0 .. std.mem.findScalarLast(u8, exe, '/') orelse return null];
        const sdk = std.mem.span(concat(&.{ bin, installed_sdk }) orelse return null);
        const probe = concat(&.{ sdk, sdk_dirs[0].path }) orelse return null;
        return if (std.c.access(probe, 0) == 0) sdk else null;
    }

    fn selfExe() ?[]const u8 {
        switch (builtin.os.tag) {
            .linux => {
                const n = std.c.readlink("/proc/self/exe", &path_buf, path_buf.len);
                return if (n > 0 and n < path_buf.len) path_buf[0..@intCast(n)] else null;
            },
            .macos => {
                var size: u32 = path_buf.len;
                if (std.c._NSGetExecutablePath(&path_buf, &size) != 0) return null;
                return std.mem.sliceTo(&path_buf, 0);
            },
            else => return null,
        }
    }

    fn xcrunSdk() ?[]const u8 {
        const out = popen("xcrun --sdk macosx --show-sdk-path 2>/dev/null", "r") orelse return null;
        defer _ = pclose(out);
        const line = fgets(&path_buf, path_buf.len, out) orelse return null;
        const sdk = std.mem.trimEnd(u8, std.mem.span(line), "\r\n");
        return if (sdk.len > 0) sdk else null;
    }

    /// `parts`, joined and NUL-terminated, in memory never freed: we `exec` soon.
    fn concat(parts: []const []const u8) ?[*:0]u8 {
        var len: usize = 0;
        for (parts) |part| len += part.len;
        const buf: [*]u8 = @ptrCast(std.c.malloc(len + 1) orelse return null);
        var i: usize = 0;
        for (parts) |part| {
            @memcpy(buf[i..][0..part.len], part);
            i += part.len;
        }
        buf[len] = 0;
        return buf[0..len :0];
    }
};

/// No libc: Windows has the command line as one string, which is kept as is.
const windows = struct {
    const w = std.os.windows;

    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, ms: w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetExitCodeProcess(process: w.HANDLE, code: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetStdHandle(which: w.DWORD) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn WriteFile(file: w.HANDLE, buf: [*]const u8, len: w.DWORD, written: ?*w.DWORD, overlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn ExitProcess(code: w.UINT) callconv(.winapi) noreturn;
    extern "kernel32" fn GetCurrentDirectoryW(len: w.DWORD, buf: [*]u16) callconv(.winapi) w.DWORD;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: [*:0]const u16) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetModuleFileNameW(module: ?w.HMODULE, buf: [*]u16, len: w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) w.DWORD;
    const INFINITE = 0xFFFFFFFF;
    const INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
    const STD_ERROR_HANDLE: w.DWORD = @bitCast(@as(i32, -12));

    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    /// `" cc <target args>`, closing the quoted zig path. The flags need no quoting (`buildCcWrapper`).
    const cc_and_target_args = L(blk: {
        var s: []const u8 = "\" cc";
        for (options.args) |arg| s = s ++ " " ++ arg;
        break :blk s;
    });

    /// The longest command line `CreateProcessW` takes.
    var cmd_buf: [32768]u16 = undefined;
    /// Static: a stack buffer this big needs compiler_rt's `__chkstk`.
    var cwd_buf: [w.PATH_MAX_WIDE]u16 = undefined;
    var sdk_buf: [w.PATH_MAX_WIDE]u16 = undefined;

    const sdk_dirs_w = blk: {
        var dirs: [sdk_dirs.len]struct { flag: []const u16, path: []const u16 } = undefined;
        for (&dirs, sdk_dirs) |*d, dir| d.* = .{ .flag = L(dir.flag), .path = L(dir.path) };
        break :blk dirs;
    };

    /// Runs `"<zig>" cc <target args> <SDK args>` followed by our command line, minus the program name.
    fn run(cmdline: []const u16) u8 {
        // The child inherits our environment. First: setting a variable can move the
        // environment block, which `getenv`'s results point into.
        if (getenv("ZIG_LOCAL_CACHE_DIR") == null) {
            const n = GetCurrentDirectoryW(cwd_buf.len, &cwd_buf);
            if (n > 0 and n < cwd_buf.len and isConfiguratorProbe(u16, cwd_buf[0..n]))
                _ = SetEnvironmentVariableW(L("ZIG_LOCAL_CACHE_DIR"), L(".zig-cache"));
        }
        const zig = getenv("ZIG") orelse L("zig");

        var len: usize = 0;
        for ([_][]const u16{ L("\""), zig, cc_and_target_args }) |part| if (!append(&len, part)) return cannotRun();
        if (options.macos_sdk) if (macosSdk()) |root| for (sdk_dirs_w) |dir| {
            for ([_][]const u16{ L(" \""), dir.flag, root, dir.path, L("\"") }) |part| if (!append(&len, part)) return cannotRun();
        };
        if (!append(&len, skipProgramName(cmdline))) return cannotRun();
        cmd_buf[len] = 0;

        var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
        startup.cb = @sizeOf(w.STARTUPINFOW);
        var child: w.PROCESS.INFORMATION = undefined;
        // No application name: `zig` is looked up like the shell does, `PATH` included.
        if (w.kernel32.CreateProcessW(null, @ptrCast(&cmd_buf), null, null, .TRUE, .{}, null, null, &startup, &child) == .FALSE)
            return cannotRun();

        var code: w.DWORD = 1;
        _ = WaitForSingleObject(child.hProcess, INFINITE);
        _ = GetExitCodeProcess(child.hProcess, &code);
        ExitProcess(code);
    }

    fn append(len: *usize, part: []const u16) bool {
        if (len.* + part.len >= cmd_buf.len) return false;
        @memcpy(cmd_buf[len.*..][0..part.len], part);
        len.* += part.len;
        return true;
    }

    /// `$ZCAML_MACOS_SDK`, else the one installed with the toolchain.
    fn macosSdk() ?[]const u16 {
        if (getenv("ZCAML_MACOS_SDK")) |sdk| return sdk;
        const n = GetModuleFileNameW(null, &sdk_buf, sdk_buf.len);
        if (n == 0 or n >= sdk_buf.len) return null;
        const bin = std.mem.findLastAny(u16, sdk_buf[0..n], L("\\/")) orelse return null;
        const suffix = L(installed_sdk);
        const probe = sdk_dirs_w[0].path;
        if (bin + suffix.len + probe.len >= sdk_buf.len) return null;
        @memcpy(sdk_buf[bin..][0..suffix.len], suffix);
        const sdk = sdk_buf[0 .. bin + suffix.len];
        @memcpy(cwd_buf[0..sdk.len], sdk);
        @memcpy(cwd_buf[sdk.len..][0..probe.len], probe);
        cwd_buf[sdk.len + probe.len] = 0;
        return if (GetFileAttributesW(@ptrCast(&cwd_buf)) != INVALID_FILE_ATTRIBUTES) sdk else null;
    }

    /// The program name ends at the closing quote if quoted (no escapes there), else at the first blank.
    fn skipProgramName(cmdline: []const u16) []const u16 {
        if (cmdline.len > 0 and cmdline[0] == '"') {
            const end = std.mem.findScalarPos(u16, cmdline, 1, '"') orelse return &.{};
            return cmdline[end + 1 ..];
        }
        const end = std.mem.findAny(u16, cmdline, L(" \t")) orelse cmdline.len;
        return cmdline[end..];
    }

    /// The environment block: `NAME=value` strings, names case-insensitive.
    fn getenv(comptime name: []const u8) ?[]const u16 {
        var env: [*:0]const u16 = w.peb().ProcessParameters.Environment;
        while (env[0] != 0) : (env += std.mem.len(env) + 1) {
            const entry = std.mem.span(env);
            if (entry.len > name.len and entry[name.len] == '=' and eqlIgnoreCase(entry[0..name.len], name))
                return entry[name.len + 1 ..];
        }
        return null;
    }

    fn eqlIgnoreCase(a: []const u16, comptime b: []const u8) bool {
        for (a, b) |x, y| if (x != y and x != std.ascii.toLower(y)) return false;
        return true;
    }

    fn cannotRun() u8 {
        const msg = "zcaml-cc: could not run zig\n";
        if (GetStdHandle(STD_ERROR_HANDLE)) |h| _ = WriteFile(h, msg, msg.len, null, null);
        return 127;
    }

    // Without libc and compiler_rt (`buildCcWrapper`: lld-link keeps ~36 KiB of it),
    // these are all that's missing.
    comptime {
        if (builtin.os.tag == .windows) {
            @export(&memcpy, .{ .name = "memcpy" });
            @export(&memset, .{ .name = "memset" });
        }
    }

    fn memcpy(noalias dest: [*]u8, noalias src: [*]const u8, len: usize) callconv(.c) [*]u8 {
        @disableIntrinsics();
        for (dest[0..len], src[0..len]) |*d, s| d.* = s;
        return dest;
    }

    fn memset(dest: [*]u8, c: c_int, len: usize) callconv(.c) [*]u8 {
        @disableIntrinsics();
        for (dest[0..len]) |*d| d.* = @truncate(@as(c_uint, @bitCast(c)));
        return dest;
    }
};

/// The macOS SDK's directories, relative to its root, and the flags passing them.
const sdk_dirs = [_]struct { flag: []const u8, path: []const u8 }{
    .{ .flag = "-F", .path = "/System/Library/Frameworks" },
    // After Zig's own libc headers: only what those lack.
    .{ .flag = "-idirafter", .path = "/usr/include" },
    .{ .flag = "-L", .path = "/usr/lib" },
};

/// The SDK installed with the toolchain, relative to `bin/`.
const installed_sdk = "/../lib/zcaml/macos-sdk";

/// Whether `cwd` is `<tmp>/ocaml-configurator<random>/c-test-<n>`, where dune-configurator
/// compiles its probes (`otherlibs/configurator/src/v1.ml`), and removes it all on exit.
fn isConfiguratorProbe(comptime T: type, cwd: []const T) bool {
    const seps = if (builtin.os.tag == .windows) &[_]T{ '/', '\\' } else &[_]T{'/'};
    const dir = std.mem.trimEnd(T, cwd, seps);
    const probe_start = (std.mem.findLastAny(T, dir, seps) orelse return false) + 1;
    const parent = dir[0 .. probe_start - 1];
    const parent_start = if (std.mem.findLastAny(T, parent, seps)) |i| i + 1 else 0;
    return startsWith(T, dir[probe_start..], "c-test-") and
        startsWith(T, parent[parent_start..], "ocaml-configurator");
}

fn startsWith(comptime T: type, s: []const T, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| if (a != b) return false;
    return true;
}
