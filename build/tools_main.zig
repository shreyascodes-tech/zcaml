//! Root of the `tools` executable. It lives in `build/` (not `build/tools/`) so the
//! tools can import `manifests/manifest.zig` relatively, exactly like the build script does.
pub const main = @import("tools/root.zig").main;
