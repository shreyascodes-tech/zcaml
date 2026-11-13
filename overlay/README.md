# zcaml opam overlay

An opam repository, for dune package management, with the few packages that
don't cross-compile as opam-repository has them: ports to dune, or small
patches. Each sorts above the versions it replaces (`+zcaml`), and is the
upstream release's sources, from its own URL, with any patch in `files/`.

Use it ahead of dune's default repositories, in `dune-workspace`:

```lisp
(repository
 (name zcaml)
 (url git+https://github.com/zcaml/zcaml-overlay.git))

(lock_dir
 (repositories zcaml overlay upstream))
```

Then `dune pkg lock`, and `dune build -x <target>` with
[zcaml](https://github.com/zcaml/zcaml)'s dune and toolchains.
Nothing here is specific to zcaml: native builds are as upstream's.

This repository is a mirror of zcaml's
[`overlay/`](https://github.com/zcaml/zcaml/tree/main/overlay), where
it's developed and tested (`ecosystem/`): send issues and changes there.

| package | what | why |
|---|---|---|
| `cmdliner.2.1.1+zcaml` | [dune-universe](https://github.com/dune-universe/opam-overlays)'s dune port, and the `cmdliner` tool, which the port leaves out (`cmdliner-tool.patch`) | upstream builds with make and `ocaml build.ml`, for the build machine only; packages' builds run the tool (`cmdliner install tool-support`) |
| `cmdliner.1.3.0+zcaml` | cmdliner 1.3.0's own dune build | upstream's opam builds with make; `cohttp-lwt-unix.5.x` requires `cmdliner < 2.0.0`, so the 2.1.1 dune port can't be selected and the make build installs a host-built library |
| `ptime.1.2.0+zcaml`, `mtime.2.2.0+zcaml` | dune-universe's dune ports | upstream builds with topkg, which asks the build machine's `uname` for `-lrt`, which Windows doesn't have |
| `zig-gmp.6.3.0` | [zig-gmp](https://github.com/shreyassanthu77/zig-gmp)'s generated sources (configured headers, tables, m4-expanded assembly) and text manifest | new: `gmp` needs GMP's configure, make and m4 output, which the source tarball doesn't have |
| `gmp.6.3.0-2+zcaml` | GMP 6.3.0, built by dune from GNU's tarball and `zig-gmp`'s sources, with `libgmp.a`, `gmp.h` and `gmp.pc`: the `gmp` library [ocaml-gmp](https://github.com/mirage/ocaml-gmp) has | ocaml-gmp runs GMP's `configure` and `make` with `sh` and `m4` (`conf-m4`), installs `libgmp.so` next to `libgmp.a`, and on Windows builds a DLL, which GMP can't build with a static library; ours needs only dune, OCaml and the C compiler |
| `zarith.1.14+zcaml` | [mirage's dune port](https://github.com/mirage/Zarith), with `gmp`, and its version in `dune-project` (`zarith-static.patch`) | upstream needs the system's GMP (`conf-gmp`), which a cross build has none of; the port's META has no version without `dune subst`, and rocq's configure checks it |
| `re2.v0.17.0+zcaml` | builds its vendored RE2 as a dune `foreign_library` with `zig c++` (`re2-cc.patch`) | upstream builds it with the build machine's `g++`/make; the dune build needs no make, `cp`, or `uname` |
| `ocaml_intrinsics.v0.17.0+zcaml` | a probe for aarch64's CRC instructions that can pass (`ocaml_intrinsics-crc.patch`) | it tries `__crc32ud`, which no compiler has, so builds for aarch64 without `+crc` and `crc_stubs.c` fails (`Target not supported`); `-mcpu=generic+crc` rather than `-march=armv8-a+crc`, which gcc and clang take but `zig cc` doesn't; and it says it's for x86_64 but not Windows only, which it builds and runs on, as for arm64 with the probe |
| `luv.0.5.14+zcaml` | builds the vendored libuv sources directly as dune `foreign_stubs` (`luv-cross.patch`): target `ocaml-config` for the platform defines, no configure/make | upstream runs libuv's `configure` and `make`, and needs libuv's DLL, which libtool doesn't build without mingw's binutils |
| `num.1.6+zcaml` | num's own dune build | upstream's opam file builds with make, with the build machine's `ocamlfind`, for compatibility with OCaml < 4.06's installs |
| `libsqlite3.3.54.1` | SQLite's amalgamation as a library with no modules, built by dune (`libsqlite3-dune.patch`): depending on it gives C stubs `sqlite3.h` and links SQLite | new: `conf-sqlite3` checks for the system's SQLite, which a cross build has none of |
| `sqlite3.5.4.2+zcaml` | with `libsqlite3` (`sqlite3-vendored.patch`) | upstream links the system's SQLite, found with the build machine's `pkg-config` |
| `zig-openssl.4.1.0` | [zig-openssl](https://github.com/shreyassanthu77/zig-openssl)'s generated sources and text manifest | new: `libopenssl` needs OpenSSL's generated configuration, which the source tarball doesn't have |
| `libopenssl.4.1.0` | OpenSSL 4.1.0, built by dune from the tarball zig-openssl pins, with `libssl.a` and `libcrypto.a` | new: `conf-libssl` checks for the system's OpenSSL, which a cross build has none of |
| `ssl.0.8.1+zcaml` | with `libopenssl` (`ssl-libopenssl.patch`): no discover or pkg-config | upstream finds OpenSSL with the build machine's `pkg-config` |
| `async_ssl.v0.17.0+zcaml` | with `libopenssl` (`async_ssl-libopenssl.patch`): OpenSSL 4.1's symbols instead of running the target's discover, and engine calls as stubs | upstream finds OpenSSL with the build machine's `pkg-config`, and runs a target executable to discover its API |
| `conf-libssl.1`–`conf-libssl.4` | empty conf packages with `PKG_CONFIG=pkg-config`, depending on `libopenssl`, at the same versions as upstream | older consumers we don't overlay (`scrypt`, `piaf.0.1.0`, `memtrace_viewer.0.14`), which find OpenSSL with the build machine's `pkg-config`; same-version packages in the first repository replace upstream's system checks |
| `zig-libpq.18.7` | [zig-libpq](https://github.com/shreyassanthu77/zig-libpq)'s generated headers (`pg_config.h`, and the Perl-generated `errcodes.h`, `kwlist_d.h` and `pg_tablespace_d.h`) and text manifest | new: `libpq` needs PostgreSQL's meson configuration and generated headers, which the source tarball doesn't have |
| `libpq.18.7` | PostgreSQL 18.7's libpq, built by dune from the tarball zig-libpq pins against `libopenssl`, with `libpq.a`, `libpq-fe.h` and `libpq.pc` | new: `conf-postgresql` checks for the system's libpq, which a cross build has none of |
| `conf-postgresql.1`, `conf-postgresql.2` | empty conf packages with `PKG_CONFIG=pkg-config`, depending on `libpq`, at the same versions as upstream | upstream runs the build machine's `pg_config` or `pkg-config libpq`; the toolchain's `pkg-config` answers `postgresql`'s discover from `libpq`'s `libpq.pc`. Older `postgresql` versions that run `pg_config` themselves still don't build |
| `conf-mingw-w64-gcc-i686.1+zcaml` | checks `x86_64-w64-mingw32-gcc`, from `conf-mingw-w64-gcc-x86_64` | upstream checks for a 32-bit mingw GCC (`i686-w64-mingw32-gcc`), which zcaml's 64-bit Windows toolchain doesn't have; packages such as `opam-core` require both the i686 and x86_64 checks on win32 |
| `base_bigstring.v0.17.0+zcaml` | a `memmem` fallback (`base_bigstring-memmem.patch`) | upstream marks itself unavailable on Windows because mingw's C library has no `memmem`, which makes every `core_kernel`-family package unsolvable for win32 |
| `index.1.6.2+zcaml` | `pread`/`pwrite` fallbacks on Windows (`index-win32.patch`) | mingw's CRT has no POSIX `pread`/`pwrite`, which `irmin-pack` pulls in |
| `rusage.1.0.0+zcaml` | a zeroed `getrusage` on Windows (`rusage-win32.patch`) | mingw has no `sys/resource.h`; `irmin-pack` pulls `rusage` in |
| `session.0.5.0+zcaml` | `lib` links `unix` (`session-unix.patch`) | upstream uses `Unix` in `Session__Memory` but doesn't declare it, so a `-linkall` link fails |
| `tally.0.0.2+zcaml` | Windows stubs for `uname`/`sysconf`/`sysctl` (`tally-win32.patch`) | upstream marks itself unavailable on Windows and its `rusage` C stubs include Unix-only headers; `utcp` pulls it in |
| `opam-core.2.6.1+zcaml`, and the matching `opam-format`, `opam-repository`, `opam-state`, `opam-solver`, `opam-client` | `<windows.h>` and no `_WIN32_WINNT` redefinition (`opam-core-win32.patch`) | upstream includes `<Windows.h>` (case-insensitive only on Windows) and sets `_WIN32_WINNT=0x602`, which `zig cc`'s `0x0a00` makes a `-Werror` redefinition; the `+zcaml` versions keep opam's `{= version}` chain together |
| `libffi.3.8.0` | libffi as a library with no modules, built from its C and assembly sources by dune (`libffi-dune.patch`): depending on it gives C stubs `ffi.h` and links libffi | new: `conf-libffi` checks for the system's libffi, which a cross build has none of |
| `ctypes-foreign.0.24.0+zcaml` | with `libffi.3.8.0` (`ctypes-foreign-libffi.patch`) | upstream finds libffi with the build machine's `pkg-config`; the patch also takes the target's `os_type` for its Windows stubs, and uses `FormatMessageA`, which `UNICODE` doesn't rename |
| `mirage-crypto-rng.2.4.1+zcaml` | the target's `os_type`, not `Sys.os_type`, for `-lbcrypt` (`mirage-crypto-rng-cross.patch`) | `discover.exe` runs on the build machine, where `Sys.os_type` isn't `Win32` |
| `mirage-crypto.0.11.3+zcaml`, `mirage-crypto-rng.0.11.3+zcaml` | `<windows.h>` (`mirage-crypto-rng-win32.patch`) | `session` pins `mirage-crypto < 1.0`, so it picks 0.11.3, which includes Windows' header with Windows' capitalisation |
| `mirage-crypto-ec`, `-pk`, `-rng-lwt`, `-rng-mirage`, `-rng-async` `.0.11.3+zcaml` | upstream's 0.11.3, unchanged | each needs `mirage-crypto` (and `-rng`) of exactly its version, so without them anything that uses one (`tls.0.17.5`, for `mehari.0.4` on Windows) takes upstream's 0.11.3 set |
| `mirage-crypto-pk.2.4.1+zcaml` | with `zarith.1.14+zcaml`, and either `mirage-crypto-rng` | upstream checks the system's GMP has `mpz_powm_sec` (`conf-gmp-powm-sec`), which a cross build has none of, for zarith's `Z.powm_sec`: our zarith's GMP, 6.3.0, has it; and it needs `mirage-crypto-rng` of exactly its version |
| `mirage-crypto-ec.2.4.1+zcaml` | with either `mirage-crypto-rng` | upstream's needs `mirage-crypto-rng` of exactly its version (as do `mirage-crypto-rng-mirage` and `-mkernel`, with which it's upstream's) |
| `ca-certs.1.0.3+zcaml` | `CertOpenSystemStoreA` (`ca-certs-unicode.patch`) | OCaml on Windows defines `UNICODE`, so `CertOpenSystemStore` is `CertOpenSystemStoreW`, which takes `LPCWSTR`, not `"ROOT"` |
| `uring.2.15.1+zcaml` | liburing's C sources as a dune library with no modules (`uring-cross.patch`), with the headers `configure` would generate checked in | upstream runs `configure` and `make` through `sh`, which a Windows build machine has neither of; the sources we build need none of `configure`'s `CONFIG_*` (`nolibc.c` and `sanitize.c` are left out) |
| `libz.1.4` | zlib as a library with no modules, built by dune (`libz-dune.patch`): depending on it gives C stubs `zlib.h` and links zlib, and installs `zlib.pc` | new: `conf-zlib` checks for the system's zlib, which a cross build has none of |
| `camlzip.1.14+zcaml` | built by dune with `libz`, and a `zip` findlib alias pointing at `camlzip`'s directory (`camlzip-dune.patch`) | upstream builds with make and the build machine's `ocamlfind`, against the system's zlib; why3's configure looks for `zip.cmi` where `ocamlfind query zip` points |
| `aws.1.2+zcaml` | links `str` (`aws-str.patch`) | upstream's library uses `Str` but doesn't declare it, so a `-linkall` link of the installed library fails with `No implementation provided for Str` |
| `curl.0.10.1+zcaml`, `curl_lwt.0.10.1+zcaml` | demotes `-I` on Debian's `/usr/include/<triple>` to `-idirafter` (`curl-partial-glibc.patch`) | that directory is a partial glibc tree; `-I` makes its `sys/cdefs.h` shadow Zig's newer one, and Zig's `netinet/in.h` then doesn't compile |
| `vlt.0.2.5+zcaml` | `vlt.mt` links `threads`, and `vlt`'s META leaves `vlt.mt` out (`vlt-threads.patch`) | upstream asks for `threads.posix`, which doesn't provide the `Thread` implementation to dune pkg; `threads` does. Its META template adds `vlt_mt` to `vlt`'s archives under the `mt` predicate, which dune sets, so `vlt` alone linked `vlt_mt` without `threads` |
| `extunix.0.4.4+zcaml` | `ppx_have` reads the features `discover` found from a file (`extunix-cross.patch`) | `ppx_have` is built with `config.ml`, so with the build machine's features: for Windows, it declares bindings that weren't compiled, and linking fails |
| `eio_windows.1.6+zcaml` | `GetModuleHandleA` (`eio_windows-unicode.patch`) | OCaml on Windows defines `UNICODE`, so `GetModuleHandle` is `GetModuleHandleW`, which takes `LPCWSTR`, not `"ntdll.dll"` |
| `eio_main.1.6+zcaml` | with `eio_windows.1.6+zcaml` | upstream's needs `eio_windows` of exactly its version |
| `merlin-lib.5.9+zcaml` | `CreateNamedPipeA` and `OpenEventA` (`merlin-lib-unicode.patch`) | OCaml on Windows defines `UNICODE`, so they're the `W` functions, which take `LPCWSTR`, not OCaml strings |
| `ocaml-index.5.9+zcaml` | with either `merlin-lib` | upstream's needs `merlin-lib` of exactly its version, and `ocaml-lsp-server` needs it (`post`) |

## Dune ports and vendored libraries

| package | what | why |
|---|---|---|
| `ocamlfind.1.9.8+zcaml` | findlib built by dune (`ocamlfind-dune.patch`): `configure` and `make`'s generated configuration files become dune rules | upstream builds with configure + make + sed/tr/grep/uname, which a Windows build host has none of; topkg and several dune packages need the `ocamlfind` binary at build time |
| `ocamlbuild.0.16.1+zcaml` | built by dune (`ocamlbuild-dune.patch`): the rules write `ocamlbuild_config.ml` and install the pack | upstream's `configure.make` + make need `cp`/`mv`/`rm`/`mkdir`/`cat`; every topkg package needs the `ocamlbuild` binary |
| `not-ocamlfind.0.15+zcaml` | built by dune (`not-ocamlfind-dune.patch`), linking findlib's library; it still execs `ocamlfind` at run time | upstream's Makefile runs `ocamlfind` to build and install, and uses `which` and `m4` |
| `ounit.2.2.7+zcaml` | the transition package's META installed by dune (`ounit-dune.patch`) | upstream's only build step is `ocamlfind install` of an 11-line META; `ounit2` itself is already dune-only |
| `process.0.2.1+zcaml` | dune port (`process-dune.patch`) | upstream builds with ocamlbuild + ocamlfind |
| `camlidl.1.13-1+zcaml` | dune port (`camlidl-dune.patch`): the Makefiles' sed and cp steps become dune rules, and dune generates the META | upstream builds with make + sed + cp + ocamlyacc/ocamllex; its Windows COM stubs still fail upstream (`int` vs `LONG`, and `FormatMessage`/`UNICODE`), so win32 is unsupported |
| `camlp5-buildscripts.0.07+zcaml` | dune port (`camlp5-buildscripts-dune.patch`): the commands go in the package's library directory, as upstream's `not-ocamlfind` install does | upstream's Makefile runs make + ocamlfind + mkdir/cp/rm/mv |
| `astring.0.8.5+zcaml`, `bos.0.3.0+zcaml`, `brr.0.0.9+zcaml`, `bytesrw.0.4.1+zcaml`, `cmarkit.0.4.0+zcaml`, `fmt.0.11.0+zcaml`, `fpath.0.7.3+zcaml`, `hmap.0.8.1+zcaml`, `jsonm.1.0.2+zcaml`, `jsont.0.4.0+zcaml`, `logs.0.10.0+zcaml`, `react.1.2.2+zcaml`, `rresult.0.7.0+zcaml`, `uucp.18.0.0+zcaml`, `uuidm.0.9.10+zcaml`, `uunf.18.0.0+zcaml`, `uuseg.18.0.0+zcaml`, `uutf.1.0.4+zcaml`, `xmlm.1.4.0+zcaml` | [dune-universe](https://github.com/dune-universe/opam-overlays)'s dune ports (`<pkg>-dune.patch`), with the optional libraries kept optional (`fmt.cli`, `logs.cli`/`logs.fmt`, `bytesrw.zlib`/`.zstd`, `jsont.brr`/`.bytesrw`/`.typegist`, `brr`'s `js_of_ocaml-compiler`) | upstream builds with topkg, which runs `ocaml pkg/pkg.ml` and needs the build machine's `ocamlfind` and `ocamlbuild` |
| `gg.1.0.0+zcaml` | a hand-written dune port (`gg-dune.patch`) | as the topkg ports above: upstream builds with topkg |
| `topkg.1.1.1+zcaml` | a hand-written dune port (`topkg-dune.patch`) | as the topkg ports above; packages that still declare `topkg` need it to resolve |
| `ez_file.0.5.0+zcaml`, `ez_cmdliner.0.5.0+zcaml`, `ocplib_stuff.0.4.0+zcaml` | the `drom` before/after hooks removed: they run `sh`, but are no-ops unless `scripts/before-build.sh` exists | a Windows build host has no `sh`; the hooks do nothing anyway |
| `io-page.3.0.0+zcaml` | the freestanding stubs as a dune `foreign_library` (`io-page-freestanding.patch`), not a make rule | its dune rule ran `make` (and pkg-config/cc/ar) to build an empty or real stub archive |
| `bls12-381.20.1+zcaml` | libblst built by dune: a `foreign_library` from its C sources plus `assembly.S` through `%{cc}` (`bls12-381-dune.patch`), with `zarith.1.14+zcaml` | upstream's dune rule runs `sh build_blst.sh`, `rm`, `cp` and `uname`; upstream is unavailable on win32 and 32-bit arches |
| `libev.4.33` | libev as a library with no modules, built by dune (`libev-dune.patch`): depending on it gives C stubs `ev.h` and links it; its `config.h` picks epoll/inotify, kqueue or select per platform | new: `conf-libev` checks for the system's libev, which a cross build has none of |
| `libogg.1.3.5` | libogg as a library with no modules, built by dune (`libogg-dune.patch`): depending on it gives C stubs `ogg/*.h` and links it | new: `conf-libogg` checks for the system's libogg |
| `libpcre.8.45` | PCRE1 as a library with no modules, built by dune (`libpcre-dune.patch`): depending on it gives C stubs `pcre.h` and links it; JIT is off | new: `conf-libpcre` checks for the system's PCRE; JIT needs executable memory, which a cross target may not have |
| `libpcre2.10.45` | PCRE2's 8-bit library as a library with no modules, built by dune (`libpcre2-dune.patch`): depending on it gives C stubs `pcre2.h` and links it; JIT is off | new: `conf-libpcre2-8` checks for the system's PCRE2; as `libpcre` for JIT |
| `libzstd.1.5.7` | Zstandard as a library with no modules, built by dune (`libzstd-dune.patch`): depending on it gives C stubs `zstd.h` and links it | new: `conf-zstd` checks for the system's zstd; `zig-pkg/` already has the sources for release compression |
| `cryptokit.1.21.1+zcaml` | with `libz` and `gmp`, and no configurator probe (`cryptokit-vendored.patch`) | upstream finds zlib with the build machine's `pkg-config` (`conf-zlib`) and checks the system GMP for `mpz_powm_sec` (`conf-gmp-powm-sec`); our GMP has it |
| `ogg.1.0.0+zcaml` | with `libogg`, and no discover (`ogg-libogg.patch`) | upstream finds libogg with the build machine's `pkg-config` (`conf-libogg`, `conf-pkg-config`) |
| `pcre.8.0.5+zcaml` | with `libpcre`, and no discover (`pcre-libpcre.patch`) | upstream finds PCRE with the build machine's `pkg-config` (`conf-libpcre`); its Win64 stubs still fail upstream (`long *` vs `caml_int_ptr`), so win32 is unsupported |
| `pcre2.8.0.4+zcaml` | with `libpcre2`, and no discover (`pcre2-libpcre2.patch`) | upstream finds PCRE2 with the build machine's `pkg-config` (`conf-libpcre2-8`) |
| `dream.1.0.0+zcaml` | drops `conf-libev` (`dream-no-libev.patch`) | `conf-libev` needs the system's libev, which a cross build has none of; lwt falls back to `select` |
| `current.0.8.0+zcaml` | drops `conf-libev` (`current-no-libev.patch`) | as `dream` |
| `current_git.0.8.0+zcaml` | upstream's, unchanged | it needs `current` of exactly its version, so without it, it takes upstream's `current` and `conf-libev` |
| `opium.0.20.0+zcaml` | drops `conf-libev` (`opium-no-libev.patch`) | as `dream` |
| `ocsigenserver.8.0.0+zcaml` | with `libz` and `libzstd` (`ocsigenserver-libz.patch`), and dune-generated config/options + dune install (`ocsigenserver-dune.patch`) | upstream finds zlib/zstd with the build machine's `pkg-config` (`conf-zlib`, `conf-zstd`), runs `sh configure` and `make install.files`; upstream is unavailable on win32 |
| `libsail.0.20.3+zcaml` | with `gmp` (`libsail-gmp.patch`) | upstream needs the system's GMP (`conf-gmp`), which a cross build has none of |
| `sail_maker.0.20.3+zcaml` | upstream's opam, re-versioned to `+zcaml` | `libsail.0.20.3+zcaml` requires `sail_maker {= version}`, so the exact-version dependency needs the same overlay version |
| `conf-c++.1.0+zcaml`, `conf-g++.1.0+zcaml` | empty conf packages: zcaml compiles C++ with `zig c++` | upstream's `conf-c++`/`conf-g++` run the build machine's `c++`/`g++`, which a cross build has none of |
| `conf-linux-libc-dev.0+zcaml` | an empty conf package: Zig ships the Linux UAPI headers | upstream preprocesses a test with the system's `cc` and needs `linux-libc-dev` installed |
| `conf-zlib.1` | an empty conf package with `PKG_CONFIG=pkg-config`, depending on `libz`, at the same version as upstream | upstream needs zlib installed on the build machine; the toolchain's `pkg-config` answers from `libz`'s `zlib.pc`, which it finds in `OCAMLPATH`; the same-version overlay package replaces upstream's system check |
| `conf-gmp.5`, `conf-gmp-powm-sec.4` | empty conf packages depending on `gmp`, at the same versions as upstream; `conf-gmp` sets `PKG_CONFIG=pkg-config` | upstream checks for the system's GMP (and its `mpz_powm_sec`), which a cross build has none of; the toolchain's `pkg-config` answers from `gmp`'s `gmp.pc`. Consumers that pass a bare `-lgmp` (`secp256k1-internal`) still don't link, and `gmpxx.h` (`class_group_vdf`) isn't built |
| `conf-pkg-config.5` | an empty conf package at the same version as upstream: zcaml's toolchains install a patched [u-config](https://github.com/skeeto/u-config) as `pkg-config` in their bin directories | upstream's `conf-pkg-config` checks for a system `pkg-config`, which a cross build host may not have; ours searches `OCAMLPATH` for a dune pkg build's packages |

## pkg-config

The toolchains install a patched `u-config` as `pkg-config` (also available as
`pkg-config-zcaml`). `conf-zlib`, `conf-libssl`, `conf-gmp` and
`conf-postgresql` set `PKG_CONFIG=pkg-config`; its queries read the vendored
libraries' `.pc` files through `OCAMLPATH`.

`conf-zlib`, `conf-libssl`, `conf-gmp`, `conf-gmp-powm-sec`, `conf-postgresql`
and `conf-pkg-config` use the same version numbers as upstream, in the first
repository. When a name and version appear in more than one repository, dune
pkg takes the first repository's package, so the overlay's empty conf package
wins without a project pin; upstream's system check never runs. This is why
the overlay must stay ahead of the default repositories.

New upstream `conf-zlib`, `conf-libssl`, `conf-gmp`, `conf-gmp-powm-sec`,
`conf-postgresql` and `conf-pkg-config` versions need matching overlay
entries. Packages patched to depend directly on vendored libraries need no conf
package.

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
[zcaml's release](https://github.com/zcaml/zcaml/releases) of it:
it sorts above the tool's version, which `.ocamlformat` asks for.
