# Contributing to zcaml

Keep changes focused, preserve upstream behavior, and explain any downstream
patch, linking upstream issues or pull requests where there are any.

## Getting set up

Install **Zig 0.17.0** and put `zig` on `PATH`. Zig fetches the pinned
dependencies into `zig-pkg/`; building OCaml needs no existing OCaml or opam.

```sh
zig build check                          # compile the build's Zig programs
zig build -Docaml -Docaml-host=native    # a native OCaml toolchain
zig build -Docaml dune -Docaml-host=native
```

OCaml installs to `zig-out/<version>/host-<host>/target-<target>/` (5.5.1 by
default, `-Docaml-version=` for another in `build.zig.zon`), Dune to
`zig-out/dune/<host>/bin/`.

The shell scripts (`ecosystem/`, `devtools/`, `scripts/`) assume an **x86_64
Linux glibc build machine** with Bash, `curl`, `tar` and `sha256sum`, plus QEMU
and Wine to run other targets' executables.

## Finding your way around

| Path | Purpose |
|---|---|
| [`build.zig`](build.zig), [`build.zig.zon`](build.zig.zon) | Build options, compiler matrix, and pinned dependencies |
| [`build/ocaml/`](build/ocaml/) | OCaml build graph, platforms, the `zcaml-cc`/`zcaml-ar` wrappers, and build tools |
| [`build/ocaml/manifests/`](build/ocaml/manifests/) | Per-version manifests generated from upstream OCaml sources |
| [`build/dune/`](build/dune/) | Dune bootstrap and its changes for cross-compiling packages |
| [`overlay/`](overlay/) | The opam overlay, mirrored to `zcaml-overlay` |
| [`devtools/`](devtools/) | ocamlformat and ocaml-lsp-server: source pins, builds, smoke tests, binary packages |
| [`ecosystem/`](ecosystem/) | Package build, link, and execution probes |
| [`test/fixtures/`](test/fixtures/), [`scripts/`](scripts/) | Toolchain fixtures, Dune and upstream OCaml test runners, shared cross-build setup |
| [`.github/workflows/`](.github/workflows/) | Releases and overlay mirroring |
| [`.depot/workflows/`](.depot/workflows/) | The ecosystem probes on Depot CI |

## Checking a change

Run `zig fmt` on changed Zig files and `zig build check` for Zig changes, then
the checks below that the change affects. Say in the pull request what you ran.

### OCaml toolchains

Build the affected host/target pair and verify it, e.g. on x86_64 Linux:

```sh
zig build -Docaml -Docaml-host=x86_64-linux-gnu -Docamldoc=true
zig build -Docaml verify -Dverify-root=zig-out/5.5.1 \
  -Docaml-host=x86_64-linux-gnu -Docaml-target=x86_64-linux-gnu
```

A single pair builds without the optional tools, and verifying a native
toolchain runs `ocamldoc`, hence `-Docamldoc=true`. For a cross compiler, add
`-Docaml-target=<triple>` to both commands (an explicit triple, not `native`).
The verifier compiles and runs [`test/fixtures/`](test/fixtures/) (bytecode,
native code, C stubs, effects, domains, threads, dynamic loading), through QEMU
or Wine where needed, and downloads the Linux sysroots QEMU needs.

For broader changes, the whole matrix (local verification runs what this
machine can; CI runs the rest on macOS and Windows):

```sh
zig build -Docaml matrix
zig build -Docaml verify -Dverify-root=zig-out/5.5.1 -Dverify-jobs=8
```

[`scripts/test-ocaml.sh`](scripts/test-ocaml.sh) runs upstream OCaml's test
suite against `zig-out/5.5.1`'s toolchains (`build`, `setup`, then
`one TEST=...`, `all` or `parallel`; `--target <triple>`); without a command,
it prints its usage.

### Dune

```sh
zig build -Docaml dune -Docaml-host=native
scripts/test-dune.sh zig-out/dune/x86_64-linux-gnu/bin/dune 3.24.2+zcaml.4
```

The version is the pinned Dune's, with the revision in
[`build/dune/tool.zig`](build/dune/tool.zig). The smoke test only checks the
version and creating a project: exercise changes to cross-compilation with an
affected project or the ecosystem probes.

### Overlay and ecosystem packages

Develop overlay packages in `overlay/`, as the existing ones are: the upstream
release's URL and checksums in `opam`, patches in `files/`, a `+zcaml` version
where one replaces an upstream version, and a row in
[`overlay/README.md`](overlay/README.md) saying what and why.

The probes ([`ecosystem/run.sh`](ecosystem/run.sh)) build packages with this
checkout's overlay (`OVERLAY=` for none), natively and for each of `$TARGETS`
(default aarch64 Linux and x86_64 Windows, the ones `probe.sh` can run). They
take a toolchain per target, for x86_64-linux-gnu, and zcaml's Dune:

```sh
zig build -Docaml -Docaml-host=native -Docaml-target=aarch64-linux-gnu
TARGETS=aarch64-linux-gnu AARCH64_LINUX_GNU_SYSROOT=<sysroot> ecosystem/run.sh \
  zig-out/ecosystem zig-out/5.5.1/host-x86_64-linux-gnu \
  zig-out/dune/x86_64-linux-gnu/bin zarith
```

Results are in the work directory's `report.md`, `results.tsv` and per-package
logs; the script succeeds even when packages fail. [`ecosystem/packages.tsv`](ecosystem/packages.tsv)
has the package, constraint, libraries, PPX rewriters, unsupported targets, and
build group. `GROUP=ml-only` (or `c-stubs`, `system-libs`) selects one group;
`PACKAGES_FILE` points at another TSV.

`packages.tsv` is generated by
[`ecosystem/generate-packages.py`](ecosystem/generate-packages.py). Its `TOP`
table is the pinned lockable top list, `EXTRA` is the few probes outside that
list, and `PATCHES` overrides a package's libraries, PPX rewriters, unsupported
targets, or group. Regenerate after editing those:

```sh
ecosystem/generate-packages.py --top 500   # 0 includes the whole TOP table
```

Don't hand-edit `packages.tsv`.

On Depot CI, with released toolchains, for all of `ecosystem/packages.tsv`, a
group, or some packages:

```sh
depot ci dispatch --repo shreyascodes-tech/zcaml --workflow ecosystem.yml --ref main \
  [--input group=ml-only] [--input packages="lwt zarith"]
```

### Developer tools

```sh
TARGETS= devtools/build.sh zig-out/devtools zig-out/5.5.1/host-x86_64-linux-gnu \
  zig-out/dune/x86_64-linux-gnu/bin ocamlformat 0.29.0
devtools/test.sh zig-out/devtools/out/x86_64-linux-gnu ocamlformat 0.29.0
```

`TARGETS` adds hosts, each needing its toolchain; macOS ones also need the SDK
(`zig build -Dmacos-sdk`, then `ZCAML_MACOS_SDK=$PWD/zig-out/macos-sdk`).
[Releasing](RELEASING.md#developer-tools) covers the rest.

## Sending a change

Open a pull request with the problem, the approach, and the checks you ran. For
a compatibility fix, include the package and version, host and target, and a
reproducer; add a fixture or probe if it shows the fix. Follow the surrounding
code's style and the Zig notes in [`AGENTS.md`](AGENTS.md). Manifests come from
`zig build generate`; `zig-pkg/` isn't part of the repository.
