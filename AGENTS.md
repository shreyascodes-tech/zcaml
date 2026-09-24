This is a zig 0.16 project. And the APIs may not be the same as your training data.

use zig env to get the lib dir and look into the source for new apis.

look at `./tools/replace-all.zig` for a good idea of the basic Io and juicy main with init arg patterns.

./zig-pkg/ is the new place where zig puts the extracted dependencies.

we use ./tools/* for transforming and/or working with lazy transforms.
eg. if we want to transform a LazyPath file we prefer to never run getPath() eagerly. we use a RunZigFile to let the zig build system schedule running the transform if/when needed.
