# u-config

`skeeto`'s [u-config](https://github.com/skeeto/u-config), a small, dependency-free
`pkg-config` implementation, vendored for the host `pkg-config` that the
toolchains install in `bin/`. Unlicense: see `UNLICENSE`.

Upstream commit: `7af1973d0ab81c50e5588002fcb99a9b3e8d047d` (v0.35.0, 2026-10-19).

## The OCAMLPATH patch

`ocamlpath.patch` is applied to this copy. It changes only the two platform
layers (`main_posix.c`, `main_windows.c`) and one constant in `src/miniwin32.h`;
the shared `src/u-config.c` is untouched.

When `PKG_CONFIG_LIBDIR` is unset, the search path comes from `OCAMLPATH`
instead of the compile-time path: for each entry `E`, `E/pkgconfig` and
`E/<name>/pkgconfig` for every name under `E` (`;`-separated on Windows). dune
pkg sets `OCAMLPATH` to its dependencies' `lib_root`s and installs pkg-config
files as `<lib>/<package>/pkgconfig/<name>.pc`, so this finds them without a
host `/usr/lib/pkgconfig` search. `PKG_CONFIG_PATH` keeps its precedence, and
`PKG_CONFIG_LIBDIR` (even empty) still wins outright. With `OCAMLPATH` unset,
behavior is upstream's.

Construction is arena-backed: expansion has no fixed 64 KiB limit. If the
4 MiB arena is exhausted, the process fails with `pkg-config: out of memory`
rather than silently truncating the search path.

On Windows the patch also makes `PKG_CONFIG_DEFINE_PREFIX` a real macro (it was
documented upstream but not implemented); builds here pass
`-DPKG_CONFIG_DEFINE_PREFIX=0`, since dune's layout is one level deeper than
`--define-prefix` assumes.

Rebase with `git apply ocamlpath.patch` on a fresh checkout of the commit above.

## Building

`build.zig` compiles these with `zig cc`/`zig build-exe` (`.ReleaseSmall`, which
is `-Os`):

```sh
# POSIX host
zig cc -Os -o pkg-config main_posix.c

# Windows host: no CRT, only kernel32, like upstream's -nostdlib mingw recipe.
# Zig's compiler-rt supplies memset/memcpy; win32_shim.c supplies wcslen.
zig build-exe main_windows.c win32_shim.c -target x86_64-windows-gnu -Osmall \
  -fno-unwind-tables -fno-builtin -fentry=mainCRTStartup -lkernel32 \
  -DPKG_CONFIG_DEFINE_PREFIX=0 --gc-sections -fstrip \
  -femit-bin=pkg-config.exe
```

## Files

| path | what |
|---|---|
| `main_posix.c` | POSIX platform layer; one translation unit |
| `main_windows.c` | mingw-w64 Win32 platform layer |
| `src/u-config.c` | shared implementation |
| `src/miniwin32.h`, `src/cmdline.c` | Win32 declarations and command line parsing |
| `win32_shim.c` | `wcslen` for the no-CRT Windows build |
| `ocamlpath.patch` | the OCAMLPATH change, against the commit above |
