//! The macOS SDK's frameworks, headers and libraries, which Zig doesn't ship, for
//! C code using Apple's frameworks (`CoreFoundation`, `Security`, ...) when not on
//! macOS: hexops' `xcode-frameworks`, a subset of Xcode's SDK.
//!
//! `zcaml-cc` takes an SDK in Xcode's layout (`cc_wrapper.zig`), from
//! `ZCAML_MACOS_SDK` or installed in a toolchain (`scripts/add-macos-sdk.sh`).
//! It isn't in the toolchain archives: those would redistribute Apple's files.
const std = @import("std");

/// `xcode_frameworks` in Xcode's layout.
pub fn layout(b: *std.Build, xcode_frameworks: *std.Build.Dependency) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    for ([_][2][]const u8{
        .{ "Frameworks", "System/Library/Frameworks" },
        .{ "include", "usr/include" },
        .{ "lib", "usr/lib" },
    }) |dirs| {
        // The archive's top directory is kept (it is part of the package hash).
        const src = xcode_frameworks.path(b.fmt("xcode-frameworks/{s}", .{dirs[0]}));
        _ = wf.addCopyDirectory(src, dirs[1], .{});
    }
    return wf.getDirectory();
}
