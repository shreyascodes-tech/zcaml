const std = @import("std");
const Context = @import("../context.zig");
const Config = @import("static.zig");
const tools = @import("../tools.zig");

const LazyPath = std.Build.LazyPath;

pub fn generate(ctx: *Context) LazyPath {
    return tools.replaceAll(
        ctx,
        ctx.ocamlRel("utils/config.common.ml.in"),
        "config.common.ml",
        &.{
            .once("@configure_input@", .str(Config.input.common)),
            .once("@EXEC_MAGIC_NUMBER@", .str(Config.magic.exec)),
            .once("@CMI_MAGIC_NUMBER@", .str(Config.magic.cmi)),
            .once("@CMO_MAGIC_NUMBER@", .str(Config.magic.cmo)),
            .once("@CMA_MAGIC_NUMBER@", .str(Config.magic.cma)),
            .once("@CMX_MAGIC_NUMBER@", .str(Config.magic.cmx)),
            .once("@CMXA_MAGIC_NUMBER@", .str(Config.magic.cmxa)),
            .once("@AST_IMPL_MAGIC_NUMBER@", .str(Config.magic.ast_impl)),
            .once("@AST_INTF_MAGIC_NUMBER@", .str(Config.magic.ast_intf)),
            .once("@CMXS_MAGIC_NUMBER@", .str(Config.magic.cmxs)),
            .once("@CMT_MAGIC_NUMBER@", .str(Config.magic.cmt)),
            .once("@LINEAR_MAGIC_NUMBER@", .str(Config.magic.linear)),
        },
    );
}
