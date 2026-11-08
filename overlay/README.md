# zcaml opam overlay

An opam repository, for dune package management, with the few packages that
don't cross-compile as opam-repository has them: ports to dune, or small
patches. Each sorts above the versions it replaces (`+zcaml`), and is the
upstream release's sources, from its own URL, with any patch in `files/`.

Use it ahead of dune's default repositories, in `dune-workspace`:

```lisp
(repository
 (name zcaml)
 (url git+https://github.com/shreyascodes-tech/zcaml-overlay.git))

(lock_dir
 (repositories zcaml overlay upstream))
```

Then `dune pkg lock`, and `dune build -x <target>` with
[zcaml](https://github.com/shreyascodes-tech/zcaml)'s dune and toolchains.
Nothing here is specific to zcaml: native builds are as upstream's.

This repository is a mirror of zcaml's
[`overlay/`](https://github.com/shreyascodes-tech/zcaml/tree/main/overlay), where
it's developed and tested (`ecosystem/`): send issues and changes there.

| package | what | why |
|---|---|---|
| `cmdliner.2.1.1+zcaml` | [dune-universe](https://github.com/dune-universe/opam-overlays)'s dune port, and the `cmdliner` tool, which the port leaves out (`cmdliner-tool.patch`) | upstream builds with make and `ocaml build.ml`, for the build machine only; packages' builds run the tool (`cmdliner install tool-support`) |
| `ptime.1.2.0+zcaml`, `mtime.2.2.0+zcaml` | dune-universe's dune ports | upstream builds with topkg, which asks the build machine's `uname` for `-lrt`, which Windows doesn't have |
| `gmp.6.3.0-2+zcaml` | [ocaml-gmp](https://github.com/mirage/ocaml-gmp), linked statically (`gmp-static.patch`) | ocaml-gmp installs `libgmp.so` next to `libgmp.a`, so programs need it at run time; on Windows it builds a DLL, which GMP can't build with a static library |
| `zarith.1.14+zcaml` | [mirage's dune port](https://github.com/mirage/Zarith), with `gmp` (`zarith-static.patch`) | upstream needs the system's GMP (`conf-gmp`), which a cross build has none of |
| `re2.v0.17.0+zcaml` | builds its vendored RE2 with the toolchain's C compiler (`re2-cc.patch`) | upstream builds it with the build machine's `g++`; and lld, unlike GNU ld, fails on the version script's libstdc++ names (`--undefined-version`) |
| `ocaml_intrinsics.v0.17.0+zcaml` | a probe for aarch64's CRC instructions that can pass (`ocaml_intrinsics-crc.patch`) | it tries `__crc32ud`, which no compiler has, so builds for aarch64 without `+crc` and `crc_stubs.c` fails (`Target not supported`); `-mcpu=generic+crc` rather than `-march=armv8-a+crc`, which gcc and clang take but `zig cc` doesn't |
| `luv.0.5.14+zcaml` | the target's, not the build machine's, OCaml configuration for libuv (`luv-cross.patch`) | upstream asks `ocamlc -config` on `PATH` for `configure --host` and for Windows' libraries; includes `WinSDKVer.h`, which is `winsdkver.h` (only Windows' file systems don't care); and needs libuv's DLL, which libtool doesn't build without mingw's binutils (an empty one, then: only bytecode would load it) |
| `num.1.6+zcaml` | num's own dune build | upstream's opam file builds with make, with the build machine's `ocamlfind`, for compatibility with OCaml < 4.06's installs |
| `libsqlite3.3.54.1` | SQLite's amalgamation as a library with no modules, built by dune (`libsqlite3-dune.patch`): depending on it gives C stubs `sqlite3.h` and links SQLite | new: `conf-sqlite3` checks for the system's SQLite, which a cross build has none of |
| `sqlite3.5.4.2+zcaml` | with `libsqlite3` (`sqlite3-vendored.patch`) | upstream links the system's SQLite, found with the build machine's `pkg-config` |
| `mirage-crypto-rng.2.4.1+zcaml` | the target's `os_type`, not `Sys.os_type`, for `-lbcrypt` (`mirage-crypto-rng-cross.patch`) | `discover.exe` runs on the build machine, where `Sys.os_type` isn't `Win32` |

`gmp` has no `substs`: dune pkg applies them before `patches` (opam, after),
and its own `src/dune` writes `src/build.sh` too.
