#!/usr/bin/env bash
# Builds ecosystem/packages.txt's packages with dune pkg for $TARGETS, without
# patching any of them: how much of opam cross-compiles with zcaml as it is.
#
#   ecosystem/run.sh <work-dir> <toolchains> <dune-bin-dir> [<package>...]
#
# <toolchains> has a toolchain per target, `target-<triple>`, for this machine
# (x86_64-linux-gnu, whose own is the native one): a release's
# `ocaml-<version>-host-x86_64-linux-gnu-target-<triple>.tar.zst`s, extracted. The
# packages are the named ones, or all. Writes <work-dir>/results.tsv (probe.sh)
# and <work-dir>/report.md.
#
#   TARGETS                    default: aarch64-linux-gnu x86_64-windows-gnu
#   JOBS                       packages at a time, default: half the CPUs
#   AARCH64_LINUX_GNU_SYSROOT  for qemu-aarch64, default: /usr/aarch64-linux-gnu
#   `zig` on PATH, and qemu-aarch64 and wine for running the targets'.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
work="$(cd "$1" && pwd)"
toolchains="$(cd "$2" && pwd)"
dune_bin="$(cd "$3" && pwd)"
shift 3

export TARGETS="${TARGETS:-aarch64-linux-gnu x86_64-windows-gnu}"
export AARCH64_LINUX_GNU_SYSROOT="${AARCH64_LINUX_GNU_SYSROOT:-/usr/aarch64-linux-gnu}"
jobs="${JOBS:-$(($(nproc) / 2 > 0 ? $(nproc) / 2 : 1))}"

# The toolchains, as a findlib configuration: `-x <triple, with _ for ->` builds
# with target-<triple>'s (findlib's names can't have `-`). The native one is also first on PATH: the lock directory's
# `ocaml-system`.
toolchain() {
  local name="$1" dir="$toolchains/target-$2"
  local suffix="${name:+($name)}"
  echo "path$suffix=\"$dir/lib/ocaml\""
  [[ -z "$name" ]] || echo "destdir$suffix=\"$dir/lib/ocaml\""
  for tool in ocamlc ocamlopt ocamldep; do echo "$tool$suffix=\"$dir/bin/$tool.opt\""; done
  echo "ocamlmklib$suffix=\"$dir/bin/ocamlmklib\""
}
{
  toolchain "" x86_64-linux-gnu
  for target in $TARGETS; do toolchain "${target//-/_}" "$target"; done
} >"$work/findlib.conf"

path="$dune_bin:$toolchains/target-x86_64-linux-gnu/bin"
for target in $TARGETS; do path="$path:$toolchains/target-$target/bin"; done
export PATH="$path:$PATH"
unset OCAMLPATH OCAMLLIB OCAMLFIND_CONF DUNE_CACHE_ROOT
export OCAMLFIND_CONF="$work/findlib.conf"
# Fresh: dune's cache (shared by the packages, as by a user's projects), and its
# copies of the repositories.
export XDG_CACHE_HOME="$work/cache"
export WINEPREFIX="$work/wine" WINEDEBUG=-all

# dune's default repositories, at fixed commits: a run's results don't depend on
# when it ran.
cat >"$work/repositories.dune" <<'EOF'
(repository
 (name overlay-pinned)
 (url git+https://github.com/ocaml-dune/opam-overlays.git#99fc2e18c45b4761ed5f6d282910c03c97e32bce))
(repository
 (name relocatable-pinned)
 (url git+https://github.com/ocaml-dune/opam-repository-relocatable.git#d64df82c7e16de819a770cabf4066a06243ed80b))
(repository
 (name upstream-pinned)
 (url git+https://github.com/ocaml/opam-repository.git#d74e2449deccd679e0a28814bfc75ba47656a7b2))
(lock_dir
 (repositories overlay-pinned relocatable-pinned upstream-pinned)
 (solver_env (sys-ocaml-version 5.5.1))
 (constraints (ocaml-system (= 5.5.1))))
EOF

# packages.txt's lines (`<package> <library>...`) for the packages asked for.
selected() {
  local line name
  while read -r line; do
    line="${line%%#*}"
    read -r name _ <<<"$line" || true
    [[ -n "$name" ]] || continue
    if [[ $# -eq 0 ]] || [[ " $* " == *" $name "* ]]; then echo "$line"; fi
  done <"$here/packages.txt"
}
selected "$@" >"$work/selected.txt"

rm -f "$work/results.tsv"
touch "$work/results.tsv"
if [[ " $TARGETS " == *" x86_64-windows-gnu "* ]]; then wineboot -i >/dev/null 2>&1; fi

# The first one alone: it fetches the repositories, which concurrent dunes wait for.
head -n 1 "$work/selected.txt" | xargs -r -L 1 "$here/probe.sh" "$work"
tail -n +2 "$work/selected.txt" | xargs -r -P "$jobs" -L 1 "$here/probe.sh" "$work"

"$here/report.sh" "$work" >"$work/report.md"
echo "$work/report.md"
