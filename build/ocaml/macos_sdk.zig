//! The macOS SDK's frameworks, headers and libraries, which Zig doesn't ship, for
//! C code using Apple's frameworks (`CoreFoundation`, `Security`, ...) when not on
//! macOS: hexops' `xcode-frameworks`, a subset of Xcode's SDK.
//!
//! `zcaml-cc` takes an SDK in Xcode's layout (`cc_wrapper.zig`): this one, for dune's
//! build, goes through `ZCAML_MACOS_SDK`. It isn't in the toolchain archives: those
//! would redistribute Apple's files.
const std = @import("std");

/// `xcode_frameworks` in Xcode's layout.
pub fn layout(b: *std.Build, xcode_frameworks: *std.Build.Dependency) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    for ([_][2][]const u8{
        .{ "Frameworks", "System/Library/Frameworks" },
        .{ "include", "usr/include" },
        .{ "lib", "usr/lib" },
    }) |dirs| _ = wf.addCopyDirectory(xcode_frameworks.path(dirs[0]), dirs[1], .{});
    return wf.getDirectory();
}
