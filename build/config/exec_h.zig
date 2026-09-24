const std = @import("std");
const State = @import("../state.zig");
const Config = @import("static.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(state: *State) LazyPath {
    return tools.configHeader(
        state.b,
        state.ocamlRel("runtime/caml/exec.h.in"),
        &.{
            .{ "EXEC_MAGIC_LENGTH", .int(Config.magic_length) },
            .{ "MAGIC_NUMBER_PREFIX", .str(Config.magic_prefix) },
            .{ "EXEC_FORMAT", .str(Config.exec_format) },
            .{ "MAGIC_NUMBER_VERSION", .str(Config.magic_version) },
        },
    );
}
