const std = @import("std");
const State = @import("../state.zig");
const Config = @import("static.zig");
const TargetConfig = @import("target.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(state: *State) LazyPath {
    const target = &state.target.result;
    return tools.replaceAll(
        state.b,
        state.ocamlRel("otherlibs/dynlink/dynlink_config.ml.in"),
        "dynlink_config.ml",
        &.{
            .once("@configure_input@", .str(Config.input.dynlink)),
            .once("@MAGIC_LENGTH@", .str(std.fmt.comptimePrint("{d}", .{Config.magic_length}))),
            .all("@QS@", .str(Config.config.qs)),
            .once("@SO@", .str(std.mem.trimStart(u8, target.dynamicLibSuffix(), "."))),
            .once("@CMO_MAGIC_NUMBER@", .str(Config.magic.cmo)),
            .once("@CMA_MAGIC_NUMBER@", .str(Config.magic.cma)),
            .once("@CMXS_MAGIC_NUMBER@", .str(Config.magic.cmxs)),
            .once("@bytecode_runtime_id@", .str(Config.bytecodeRuntimeId(state.target.result))),
            .once("@target@", .str(TargetConfig.ocamlTriple(state.b.allocator, target.*))),
        },
    );
}
