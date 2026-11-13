# Releasing zcaml

Each distribution releases on its own, from a tag; the overlay publishes itself
from `main`. For local builds and checks, see [Contributing](CONTRIBUTING.md).

| Distribution | Tag | Workflow |
|---|---|---|
| OCaml | `ocaml-v<version>[-<revision>]` | [`toolchains.yml`](.github/workflows/toolchains.yml) |
| Dune | `dune-v<version>-zcaml.<revision>` | [`dune.yml`](.github/workflows/dune.yml) |
| Developer tool | `<package>-v<version>-zcaml.<revision>` | [`devtools.yml`](.github/workflows/devtools.yml) |

The revision counts zcaml's builds of one upstream version: `ocaml-v5.5.1` is
the first of OCaml 5.5.1 and `ocaml-v5.5.1-2` the second, while Dune's and the
tools' start at `zcaml.1`. Dune's is also in `dune --version`
(`3.24.2+zcaml.5`, `+` for the tag's `-`).

To release: prepare the component (below), optionally try the workflow on a
branch, which builds and tests without publishing, then push the tag:

```sh
gh workflow run toolchains.yml --ref <branch> -f ocaml_version=5.5.1
gh workflow run dune.yml --ref <branch> -f ocaml_tag=ocaml-v5.5.1-8
gh workflow run devtools.yml --ref <branch> -f package=ocamlformat -f version=0.29.0

git tag <tag> && git push origin <tag>
```

CI publishes the GitHub Release once every build and test passes. Re-running a
tag's workflow uploads over its assets (`--clobber`), e.g. to finish a failed
run.

When updating everything, the order is OCaml, then Dune (bootstrapped with the
latest OCaml release), then the developer tools, then their overlay packages.

## OCaml toolchains

- A new upstream version: add its `ocaml_*` dependency to
  [`build.zig.zon`](build.zig.zon), first (the newest is the default), run
  `zig build generate` for its manifest in `build/ocaml/manifests/`, adapt
  `build/ocaml/` to upstream's build changes, and add it to `toolchains.yml`'s
  `ocaml_version` choices.
- A rebuild: just the next revision's tag.

CI builds the full matrix on Linux and verifies the Linux-hosted toolchains
(natively, QEMU, Wine), then the macOS- and Windows-hosted ones on macOS (with
Rosetta) and Windows. Test programs compiled for an OS other than the verifying
one run where they can, before publishing
`ocaml-<version>-host-<host>-target-<target>.tar.zst` archives. The archive names
have no revision: link to the tag's release.

## Dune

- Pin the Dune release in `build.zig.zon` and set `revision` in
  [`build/dune/tool.zig`](build/dune/tool.zig) (1 for a new upstream version).
- A new upstream Dune: check that `addCrossHooks`' replacements still apply
  (the build fails if one doesn't) and test cross-compiling packages.

CI bootstraps all seven hosts' Dune on Linux with the latest `ocaml-v*` release
(or the `ocaml_tag` input), smoke-tests them (distro containers, Wine, macOS
with Rosetta), checks the tag names the built version, and publishes
`dune-<version>-zcaml.<revision>-<host>.tar.zst`, each with `bin/dune`. Dune
works with any OCaml version.

## Developer tools

1. Add the tool's line to [`devtools/devtools.txt`](devtools/devtools.txt):
   `<package> <version> <ocaml> <license> <homepage> <source-url> <sha256>`,
   `<ocaml>` being the OCaml release it's for (`5.5` for ocaml-lsp-server) or
   `-` for any (ocamlformat).
2. Check `devtools.yml`'s `OCAML_TAG`, `OCAML_VERSION` and `DUNE_TAG`. The OCaml
   version must be [`scripts/cross-env.sh`](scripts/cross-env.sh)'s, 5.5.1.
3. Put any fixes the build needs in `overlay/`. A new tool also needs a tag
   trigger in `devtools.yml` and a test in [`devtools/test.sh`](devtools/test.sh).

CI builds the tool's sources with dune pkg for all seven hosts, tests them
(formatting a snippet, answering an LSP initialize), and publishes
`<package>-<version>-zcaml.<revision>-<host>.tar.gz` (dune pkg doesn't extract
`.tar.zst`), each with the tool's files and an install file, and `SHA256SUMS`.

**Then, by hand**, make the overlay's binary packages of the release:

```sh
devtools/overlay.sh <tag>
```

It writes `overlay/packages/<package>/<package>.<version>+zcaml.<revision>-<host>/`
from the release's `SHA256SUMS`. Add the version to `overlay/README.md`'s
pre-built table and commit to `main`.

## The overlay

[`overlay.yml`](.github/workflows/overlay.yml) mirrors `overlay/` to
[`zcaml-overlay`](https://github.com/zcaml/zcaml-overlay)'s `main` on
each push to `main` that changes it (`git subtree split`, fast-forward only,
with the `OVERLAY_DEPLOY_KEY` deploy key); `gh workflow run overlay.yml` retries
it. It doesn't test packages: run the affected ones through the ecosystem probes
first, on Depot CI:

```sh
depot ci dispatch --repo zcaml/zcaml --workflow ecosystem.yml --ref main \
  --input packages="<packages>"
```

## After a release

Point what builds with it at the new release:

- **OCaml:** `ocaml_tag`'s default and `OCAML_TAG` in
  [`.depot/workflows/ecosystem.yml`](.depot/workflows/ecosystem.yml), and
  `OCAML_TAG` in `devtools.yml`. For a new OCaml version, also its `5.5.1` in
  `scripts/cross-env.sh`, `devtools.yml`'s `OCAML_VERSION`, and `toolchains.yml`'s
  default.
- **Dune:** `DUNE_TAG` in `devtools.yml`, and `dune_tag`'s default and `DUNE_TAG`
  in `.depot/workflows/ecosystem.yml`.
- **Any:** the download table in [`README.md`](README.md).

For a developer tool, check the overlay mirror ran, then that a project picks
the binary: `dune tools exec ocamllsp`, or `dune tools install ocamlformat` and
`dune fmt`.
