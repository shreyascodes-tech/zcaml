#!/usr/bin/env bash
# Builds ecosystem/packages.tsv's packages with dune pkg for $TARGETS, as opam
# has them but for zcaml's overlay (overlay/): how much of opam cross-compiles
# with zcaml.
#
#   ecosystem/run.sh <work-dir> <toolchains> <dune-bin-dir> [<package>...]
#
# <toolchains> has a toolchain per target, `target-<triple>`, for this machine
# (x86_64-linux-gnu, whose own is the native one): a release's
# `ocaml-<version>-host-x86_64-linux-gnu-target-<triple>.tar.zst`s, extracted. The
# packages are the named ones, or all. Writes <work-dir>/results.tsv (probe.sh)
# and <work-dir>/report.md.
#
# packages.tsv columns: package, constraint, libraries, ppx, unsupported, group.
# Empty libraries means the package name; a comma separates several entries; a
# single `-` builds the package without linking a library. The `group` column is
# ml-only, c-stubs, or system-libs.
#
#   PACKAGES_FILE              default: $here/packages.tsv
#   GROUP                      only packages in this group, default: all
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
jobs="${JOBS:-$(nproc)}"
# Each probe's dune builds share the machine with the other probes.
export DUNE_JOBS="${DUNE_JOBS:-2}"

# $work's findlib configuration and dune repositories, and the environment.
# shellcheck source=../scripts/cross-env.sh
source "$here/../scripts/cross-env.sh"

# packages.tsv's rows, as probe.sh's `<package>[<constraint>] <library>...`
# arguments, for the packages asked for and the $GROUP, if any.
packages_file="${PACKAGES_FILE:-$here/packages.tsv}"
group="${GROUP:-}"
selected() {
  awk -F '\t' -v group="$group" -v want="$*" '
    BEGIN {
      want_n = split(want, a, " ")
      for (i = 1; i <= want_n; i++) if (a[i] != "") w[a[i]] = 1
    }
    /^#/ || NF == 0 { next }
    {
      pkg = $1
      g = $6 == "" ? "other" : $6
      if (group != "" && group != "all" && g != group) next
      if (want_n > 0 && !(pkg in w)) next
      line = pkg $2
      if ($3 != "") {
        m = split($3, x, ",")
        for (i = 1; i <= m; i++) if (x[i] != "") line = line " " x[i]
      }
      if ($4 != "") {
        m = split($4, x, ",")
        for (i = 1; i <= m; i++) if (x[i] != "") line = line " pps:" x[i]
      }
      if ($5 != "") {
        m = split($5, x, ",")
        for (i = 1; i <= m; i++) if (x[i] != "") line = line " !" x[i]
      }
      print line
    }
  ' "$packages_file"
}
selected "$@" >"$work/selected.txt"
if [[ ! -s "$work/selected.txt" ]]; then
  echo "no packages selected from $packages_file" >&2
  exit 1
fi

# Longest first: these took longest in previous runs, so they start first and
# don't leave the run waiting for them at the end.
heavy="async core_unix re2 core cohttp-lwt-unix ppx_jane tls ocamlformat-lib x509 ppx_expect extunix luv progress uuseg omd eio_main ppx_yojson_conv ppx_sexp_conv camomile uucp lwt_ppx sedlex bisect_ppx_ng sqlite3"
awk -v heavy="$heavy" '
  BEGIN { n = split(heavy, a, " "); for (i = 1; i <= n; i++) p[a[i]] = i }
  {
    name = $1
    sub(/[<>=].*/, "", name)
    print (name in p ? p[name] : 1000) "\t" NR "\t" $0
  }
' "$work/selected.txt" | sort -t$'\t' -k1,1n -k2,2n | cut -f3- >"$work/selected.sorted"
mv "$work/selected.sorted" "$work/selected.txt"

rm -f "$work/results.tsv"
touch "$work/results.tsv"
if [[ " $TARGETS " == *" x86_64-windows-gnu "* ]]; then wineboot -i >/dev/null 2>&1; fi

# Lock one package alone first: it fetches the repositories, which concurrent
# dunes wait for. Only the lock: the package's build runs in parallel with the
# others, so the warm-up doesn't serialize a whole build.
head -n 1 "$work/selected.txt" | PROBE_LOCK_ONLY=1 xargs -r -L 1 "$here/probe.sh" "$work"
xargs -r -P "$jobs" -L 1 "$here/probe.sh" "$work" <"$work/selected.txt"

"$here/report.sh" "$work" >"$work/report.md"
echo "$work/report.md"
