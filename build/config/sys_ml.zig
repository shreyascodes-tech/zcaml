const std = @import("std");
const Context = @import("../context.zig");
const Config = @import("static.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(ctx: *Context) LazyPath {
    return tools.replaceAll(
        ctx,
        ctx.ocamlRel("stdlib/sys.ml.in"),
        "sys.ml",
        &.{
            .once("@configure_input@", .str(Config.input.sys)),
            .once("@VERSION@", .str(Config.version)),
            .once("@OCAML_DEVELOPMENT_VERSION@", .str(Config.config.no)),
            .once("@OCAML_VERSION_MAJOR@", .str(std.fmt.comptimePrint("{d}", .{Config.version_major}))),
            .once("@OCAML_VERSION_MINOR@", .str(std.fmt.comptimePrint("{d}", .{Config.version_minor}))),
            .once("@OCAML_VERSION_PATCHLEVEL@", .str(std.fmt.comptimePrint("{d}", .{Config.version_patchlevel}))),
            .once("@OCAML_RELEASE_EXTRA@", .str(Config.config.none)),
        },
    );
}
