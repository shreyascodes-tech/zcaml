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

| package | what | why |
|---|---|---|
| `cmdliner.2.1.1+zcaml` | [dune-universe](https://github.com/dune-universe/opam-overlays)'s dune port, and the `cmdliner` tool, which the port leaves out (`cmdliner-tool.patch`) | upstream builds with make and `ocaml build.ml`, for the build machine only; packages' builds run the tool (`cmdliner install tool-support`) |
| `ptime.1.2.0+zcaml`, `mtime.2.2.0+zcaml` | dune-universe's dune ports | upstream builds with topkg, which asks the build machine's `uname` for `-lrt`, which Windows doesn't have |
| `gmp.6.3.0-2+zcaml` | [ocaml-gmp](https://github.com/mirage/ocaml-gmp), linked statically (`gmp-static.patch`) | ocaml-gmp installs `libgmp.so` next to `libgmp.a`, so programs need it at run time; on Windows it builds a DLL, which GMP can't build with a static library |
| `zarith.1.14+zcaml` | [mirage's dune port](https://github.com/mirage/Zarith), with `gmp` (`zarith-static.patch`) | upstream needs the system's GMP (`conf-gmp`), which a cross build has none of |

`gmp` has no `substs`: dune pkg applies them before `patches` (opam, after),
and its own `src/dune` writes `src/build.sh` too.
