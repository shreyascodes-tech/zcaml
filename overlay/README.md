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
| `cmdliner.1.3.0+zcaml` | cmdliner 1.3.0's own dune build | upstream's opam builds with make; `cohttp-lwt-unix.5.x` requires `cmdliner < 2.0.0`, so the 2.1.1 dune port can't be selected and the make build installs a host-built library |
| `ptime.1.2.0+zcaml`, `mtime.2.2.0+zcaml` | dune-universe's dune ports | upstream builds with topkg, which asks the build machine's `uname` for `-lrt`, which Windows doesn't have |
| `gmp.6.3.0-2+zcaml` | [ocaml-gmp](https://github.com/mirage/ocaml-gmp), linked statically (`gmp-static.patch`) | ocaml-gmp installs `libgmp.so` next to `libgmp.a`, so programs need it at run time; on Windows it builds a DLL, which GMP can't build with a static library |
| `zarith.1.14+zcaml` | [mirage's dune port](https://github.com/mirage/Zarith), with `gmp` (`zarith-static.patch`) | upstream needs the system's GMP (`conf-gmp`), which a cross build has none of |
| `re2.v0.17.0+zcaml` | builds its vendored RE2 with the toolchain's C compiler (`re2-cc.patch`) | upstream builds it with the build machine's `g++`; and lld, unlike GNU ld, fails on the version script's libstdc++ names (`--undefined-version`) |
| `ocaml_intrinsics.v0.17.0+zcaml` | a probe for aarch64's CRC instructions that can pass (`ocaml_intrinsics-crc.patch`) | it tries `__crc32ud`, which no compiler has, so builds for aarch64 without `+crc` and `crc_stubs.c` fails (`Target not supported`); `-mcpu=generic+crc` rather than `-march=armv8-a+crc`, which gcc and clang take but `zig cc` doesn't; and it says it's for x86_64 but not Windows only, which it builds and runs on, as for arm64 with the probe |
| `luv.0.5.14+zcaml` | the target's, not the build machine's, OCaml configuration for libuv (`luv-cross.patch`) | upstream asks `ocamlc -config` on `PATH` for `configure --host` and for Windows' libraries; includes `WinSDKVer.h`, which is `winsdkver.h` (only Windows' file systems don't care); and needs libuv's DLL, which libtool doesn't build without mingw's binutils (an empty one, then: only bytecode would load it) |
| `num.1.6+zcaml` | num's own dune build | upstream's opam file builds with make, with the build machine's `ocamlfind`, for compatibility with OCaml < 4.06's installs |
| `libsqlite3.3.54.1` | SQLite's amalgamation as a library with no modules, built by dune (`libsqlite3-dune.patch`): depending on it gives C stubs `sqlite3.h` and links SQLite | new: `conf-sqlite3` checks for the system's SQLite, which a cross build has none of |
| `sqlite3.5.4.2+zcaml` | with `libsqlite3` (`sqlite3-vendored.patch`) | upstream links the system's SQLite, found with the build machine's `pkg-config` |
| `zig-openssl.4.1.0` | [zig-openssl](https://github.com/shreyassanthu77/zig-openssl)'s generated sources and text manifest | new: `libopenssl` needs OpenSSL's generated configuration, which the source tarball doesn't have |
| `libopenssl.4.1.0` | OpenSSL 4.1.0, built by dune from the tarball zig-openssl pins, with `libssl.a` and `libcrypto.a` | new: `conf-libssl` checks for the system's OpenSSL, which a cross build has none of |
| `conf-libssl.4+zcaml` | with `libopenssl`; a self-contained `pkg-config` shim points consumers at it, with no `conf-pkg-config` | upstream `ssl` and `async_ssl` find OpenSSL with the build machine's `pkg-config` |
| `libffi.3.8.0` | libffi as a library with no modules, built from its C and assembly sources by dune (`libffi-dune.patch`): depending on it gives C stubs `ffi.h` and links libffi | new: `conf-libffi` checks for the system's libffi, which a cross build has none of |
| `ctypes-foreign.0.24.0+zcaml` | with `libffi.3.8.0` (`ctypes-foreign-libffi.patch`) | upstream finds libffi with the build machine's `pkg-config`; the patch also takes the target's `os_type` for its Windows stubs, and uses `FormatMessageA`, which `UNICODE` doesn't rename |
| `mirage-crypto-rng.2.4.1+zcaml` | the target's `os_type`, not `Sys.os_type`, for `-lbcrypt` (`mirage-crypto-rng-cross.patch`) | `discover.exe` runs on the build machine, where `Sys.os_type` isn't `Win32` |
| `mirage-crypto-pk.2.4.1+zcaml` | with `zarith.1.14+zcaml`, and either `mirage-crypto-rng` | upstream checks the system's GMP has `mpz_powm_sec` (`conf-gmp-powm-sec`), which a cross build has none of, for zarith's `Z.powm_sec`: our zarith's GMP, 6.3.0, has it; and it needs `mirage-crypto-rng` of exactly its version |
| `mirage-crypto-ec.2.4.1+zcaml` | with either `mirage-crypto-rng` | upstream's needs `mirage-crypto-rng` of exactly its version (as do `mirage-crypto-rng-mirage` and `-mkernel`, with which it's upstream's) |
| `ca-certs.1.0.3+zcaml` | `CertOpenSystemStoreA` (`ca-certs-unicode.patch`) | OCaml on Windows defines `UNICODE`, so `CertOpenSystemStore` is `CertOpenSystemStoreW`, which takes `LPCWSTR`, not `"ROOT"` |
| `uring.2.15.1+zcaml` | liburing's C sources as a dune library with no modules (`uring-cross.patch`), with the headers `configure` would generate checked in | upstream runs `configure` and `make` through `sh`, which a Windows build machine has neither of; the sources we build need none of `configure`'s `CONFIG_*` (`nolibc.c` and `sanitize.c` are left out) |
| `libz.1.4` | zlib as a library with no modules, built by dune (`libz-dune.patch`): depending on it gives C stubs `zlib.h` and links zlib | new: `conf-zlib` checks for the system's zlib, which a cross build has none of |
| `camlzip.1.14+zcaml` | built by dune with `libz` (`camlzip-dune.patch`) | upstream builds with make and the build machine's `ocamlfind`, against the system's zlib |
| `extunix.0.4.4+zcaml` | `ppx_have` reads the features `discover` found from a file (`extunix-cross.patch`) | `ppx_have` is built with `config.ml`, so with the build machine's features: for Windows, it declares bindings that weren't compiled, and linking fails |
| `eio_windows.1.6+zcaml` | `GetModuleHandleA` (`eio_windows-unicode.patch`) | OCaml on Windows defines `UNICODE`, so `GetModuleHandle` is `GetModuleHandleW`, which takes `LPCWSTR`, not `"ntdll.dll"` |
| `eio_main.1.6+zcaml` | with `eio_windows.1.6+zcaml` | upstream's needs `eio_windows` of exactly its version |
| `merlin-lib.5.9+zcaml` | `CreateNamedPipeA` and `OpenEventA` (`merlin-lib-unicode.patch`) | OCaml on Windows defines `UNICODE`, so they're the `W` functions, which take `LPCWSTR`, not OCaml strings |
| `ocaml-index.5.9+zcaml` | with either `merlin-lib` | upstream's needs `merlin-lib` of exactly its version, and `ocaml-lsp-server` needs it (`post`) |

`gmp` has no `substs`: dune pkg applies them before `patches` (opam, after),
and its own `src/dune` writes `src/build.sh` too.

## Pre-built dev tools

dune pkg's dev tools, `dune tools exec ocamllsp` (what an editor runs) and
`dune fmt` (after `dune tools install ocamlformat`), build the tool for the
project: ocamlformat of `.ocamlformat`'s version, ocaml-lsp-server for its
compiler. With this repository, they download it instead, if it's one of these
(zcaml's `devtools/`, every host's, from the tool's sources):

| package | for |
|---|---|
| `ocamlformat.0.29.0+zcaml.1-<host>` | any OCaml |
| `ocaml-lsp-server.1.28.1+zcaml.1-<host>` | OCaml 5.5 |

One package per host, which `available` picks (musl's on Alpine), of
[zcaml's release](https://github.com/shreyascodes-tech/zcaml/releases) of it:
it sorts above the tool's version, which `.ocamlformat` asks for.
