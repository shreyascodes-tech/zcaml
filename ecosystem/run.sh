#!/usr/bin/env bash
# Builds ecosystem/packages.txt's packages with dune pkg for $TARGETS, as opam has
# them but for zcaml's overlay (overlay/): how much of opam cross-compiles with zcaml.
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
#   OVERLAY                    zcaml's overlay, default: this checkout's; empty: none
#   OVERLAYS                   more opam repositories, ahead of it: `<name>=<url>`s
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

# $work's findlib configuration and dune repositories, and the environment.
# shellcheck source=../scripts/cross-env.sh
source "$here/../scripts/cross-env.sh"

# packages.txt's lines (`<package>[<constraint>] <library>...`) for the packages
# asked for.
selected() {
  local line name
  while read -r line; do
    line="${line%%#*}"
    read -r name _ <<<"$line" || true
    name="${name%%[<>=]*}"
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
