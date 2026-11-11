# zcaml

> [!NOTE]
> The entire README is LLM generated so you may want to not readd it. I will rewrite it to be more me when I have time sorry :)

zcaml makes it easier to get a working OCaml environment and build applications
across platforms. It started with cross-compilation and grew into a broader goal:
getting you from a fresh machine to building OCaml applications with less setup.

## The Three parts

### Distributions

Prebuilt **OCaml toolchains, Dune, OCaml-LSP, and ocamlformat** for Linux, macOS,
and Windows. Download the tools you need and use them directly, including
compilers targeting other platforms.

### Overlay

An opam repository with package fixes, cross-compilation support, and prebuilt
developer tools. Add it to your existing workflow wherever needed.

### CLI (in development)

A manager that brings the pieces together: installing tools, managing versions,
adding targets, and setting up SDKs.

You'll use ordinary commands such as `dune`, `ocamllsp`, and `ocamlformat`, with
zcaml selecting the appropriate versions from your project's requirements.

**The distributions and overlay are available today and can be used without the
CLI.** They can also be used independently of each other, subject to individual
tools' and packages' build requirements.

## Get started

### Download the tools

Prebuilt binaries are available in
[Releases](https://github.com/shreyascodes-tech/zcaml/releases):

| Tool | Release |
|---|---|
| OCaml | [5.5.1](https://github.com/shreyascodes-tech/zcaml/releases/tag/ocaml-v5.5.1-13) |
| Dune | [3.24.2+zcaml.4](https://github.com/shreyascodes-tech/zcaml/releases/tag/dune-v3.24.2-zcaml.4) |
| OCaml-LSP | [1.28.1, for OCaml 5.5](https://github.com/shreyascodes-tech/zcaml/releases/tag/ocaml-lsp-server-v1.28.1-zcaml.1) |
| ocamlformat | [0.29.0](https://github.com/shreyascodes-tech/zcaml/releases/tag/ocamlformat-v0.29.0-zcaml.1) |

Choose the archive for your platform, extract it, and add its `bin` directory to
`PATH`.

OCaml archives specify both a **host**, where the compiler runs, and a **target**,
where the compiled application runs. Choose the same host and target for native
development.

The OCaml toolchains use **Zig 0.17.0** for C/C++ compilation and linking. Make
`zig` available on `PATH`; a separate GCC or MinGW installation is unnecessary
for the toolchain.

### Use the overlay

Add the repository ahead of Dune's default repositories in `dune-workspace`:

```lisp
(repository
 (name zcaml)
 (url git+https://github.com/shreyascodes-tech/zcaml-overlay.git))

(lock_dir
 (repositories zcaml overlay upstream))
```

If you already configure repositories or a lock directory, incorporate these
entries into that configuration.

For supported versions and platforms, the overlay also lets Dune download
prebuilt developer tools:

```sh
dune tools install ocamlformat
dune fmt
```

Editors using `dune tools exec ocamllsp` can use the prebuilt language server
matching the project's compiler.

See the [overlay README](overlay/README.md) for available packages, tool versions,
and the reasons behind each patch. Some packages may have additional build
requirements, including Zig.

## Goals

- **A complete starting point.** OCaml, Dune, language-server support, formatting,
  and supporting toolchains.
- **Less environment management.** Get building without compiling a switch or
  hunting down a platform-specific C compiler.
- **Project-aware tooling.** Select tool versions from existing project
  requirements.
- **Straightforward cross-compilation.** Build applications for other platforms,
  including dependencies, PPX rewriters, and C/C++ stubs.
- **A more portable ecosystem.** Fix compatibility problems and contribute
  improvements upstream.

## Compatibility comes first

zcaml's tools should stay as close to their upstream versions as possible, with
focused additions needed to achieve these goals.

**If something works with the stock tools and fails under zcaml, that is a bug.**

zcaml is not aiming to introduce a new OCaml dialect, application framework,
package format, or required project structure.

We intend to upstream changes. The overlay will likely remain useful long-term as
ecosystem compatibility work continues. We hope upstream Dune eventually absorbs
or supersedes the Dune changes.

### OCaml versions

The current support baseline is **OCaml 5.5 and newer**, which provide upstream
support for fully relocatable installations.

Supporting older releases through backports or patches is a possible future
direction, rather than a current goal.

## Platforms

Dune, OCaml-LSP, ocamlformat, and the full set of OCaml cross-compilers are
distributed for:

| Host platform | Architectures |
|---|---|
| Linux, glibc and musl | x86_64, aarch64 |
| macOS | x86_64, aarch64 |
| Windows, GNU ABI | x86_64 |

OCaml compiler targets include all of the above, plus Linux **riscv64**,
**powerpc64le**, and **s390x**, with both glibc and musl. Those additional Linux
platforms also have native OCaml toolchains.

Cross-compiling Dune projects currently requires manual target configuration.
Package compatibility depends on the package and target platform. macOS targets
need an SDK when using Apple frameworks; the planned CLI will handle SDK setup.

## How it works

zcaml builds upstream OCaml with Zig and provides target-specific wrappers around
`zig cc` and `zig c++`, plus `ar`, `ranlib`, `objcopy`, `dlltool`, `lib`, and `rc`
that run the corresponding Zig tools.

Its Dune integration cross-compiles package dependencies while keeping build-time
tools, such as PPX rewriters, runnable on the development machine. The overlay
supplies package fixes where needed.

Release workflows smoke-test the tools across platforms. The
[ecosystem probes](ecosystem/) check package builds, linking, and execution.

<details>
<summary>Building from source</summary>

Requires Zig 0.17.0.

```sh
# Build a native OCaml toolchain
zig build -Docaml -Docaml-host=native

# Build a compiler targeting Windows
zig build -Docaml -Docaml-host=native \
  -Docaml-target=x86_64-windows-gnu

# Build Dune for your machine
zig build -Docaml dune -Docaml-host=native
```

OCaml toolchains are installed under:

```text
zig-out/<version>/host-<host>/target-<target>/
```

See [`build.zig`](build.zig) for build options, [`devtools/`](devtools/) for
developer-tool builds, and [the release workflows](.github/workflows/) for
packaging and verification.

</details>

## Contributing

Bug reports, package compatibility fixes, and improvements to the developer
experience are welcome.

See [Contributing](CONTRIBUTING.md) for setup, builds, and checks, and
[Releasing](RELEASING.md) for distribution releases and overlay publication.

[Open an issue](https://github.com/shreyascodes-tech/zcaml/issues) with your tool
versions, host and target platforms, and a reproducer where possible.

## License

zcaml is [MIT licensed](LICENSE). Distributed tools retain their respective
upstream licenses.
