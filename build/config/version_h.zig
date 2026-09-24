const std = @import("std");
const Context = @import("../context.zig");
const Config = @import("static.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(ctx: *Context) LazyPath {
    return tools.configHeader(
        ctx.b,
        ctx.ocamlRel("runtime/caml/version.h.in"),
        &.{
            .{ "OCAML_VERSION_MAJOR", .int(Config.version_major) },
            .{ "OCAML_VERSION_MINOR", .int(Config.version_minor) },
            .{ "OCAML_VERSION_PATCHLEVEL", .int(Config.version_patchlevel) },
            .{ "OCAML_VERSION_ADDITIONAL", .str(Config.version_extra) },
            .{ "OCAML_VERSION_EXTRA", .str(Config.version_extra) },
            .{ "OCAML_VERSION", .int(Config.version_number) },
            .{ "OCAML_VERSION_STRING", .str(Config.version) },
            .{ "OCAML_RELEASE_NUMBER", .int(Config.release_number) },
        },
    );
}
