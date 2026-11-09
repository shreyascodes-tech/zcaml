#!/usr/bin/env bash
# Builds a dev tool (devtools.txt) for this machine and each of $TARGETS: its
# release's sources as the project, with dune pkg, so its executables are each
# target's (as a dependency's, they'd be the build machine's).
#
#   devtools/build.sh <work-dir> <toolchains> <dune-bin-dir> <package> <version>
#
# <toolchains> as ecosystem/run.sh's. Installs the package's files but its
# libraries (bin/, doc/, man/, ...) to <work-dir>/out/<target>/, this machine's as
# x86_64-linux-gnu.
#
#   TARGETS          the targets, besides this machine
#   ZCAML_MACOS_SDK  the macOS SDK (zig build -Dmacos-sdk), for macOS targets
#   OVERLAY, OVERLAYS  as ecosystem/run.sh's
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
work="$(cd "$1" && pwd)"
toolchains="$(cd "$2" && pwd)"
dune_bin="$(cd "$3" && pwd)"
package="$4"
version="$5"
export TARGETS="${TARGETS:-}"

if [[ " $TARGETS " == *-macos-* && -z "${ZCAML_MACOS_SDK:-}" ]]; then
  echo "error: building for macOS needs ZCAML_MACOS_SDK" >&2
  exit 1
fi

read -r url sha256 < <(awk -v p="$package" -v v="$version" '$1 == p && $2 == v { print $6, $7 }' "$here/devtools.txt")
if [[ -z "${url:-}" ]]; then
  echo "error: $package $version isn't in devtools.txt" >&2
  exit 1
fi

# shellcheck source=../scripts/cross-env.sh
source "$here/../scripts/cross-env.sh"

src="$work/src"
rm -rf "$src" "$work/out"
mkdir -p "$src"
curl -fsSL "$url" -o "$work/source"
echo "$sha256  $work/source" | sha256sum -c --quiet
tar -xaf "$work/source" -C "$src" --strip-components=1
cd "$src"
{
  echo "(lang dune 3.24)"
  cat "$work/repositories.dune"
} >dune-workspace

dune pkg lock
for target in x86_64-linux-gnu $TARGETS; do
  context=default x=()
  if [[ $target != x86_64-linux-gnu ]]; then
    context="default.${target//-/_}"
    x=(-x "${target//-/_}")
  fi
  # All of the project's packages' (the lock directory is for all of them): the
  # .install file says which files are $package's.
  dune build "${x[@]}" --profile release @install
  install="_build/$context/$package.install"
  [[ $context == default ]] || install="_build/$context/$package-${target//-/_}.install"
  out="$work/out/$target"
  mkdir -p "$out"
  # Its sections' files, as in _build/install/<context>/ (not lib's, lib_root's,
  # libexec's, stublibs' and toplevel's: the libraries), and an install file for
  # them: dune pkg installs a package's.
  declare -A entries=()
  while read -r section file; do
    rel="${file#_build/install/$context/}"
    # Windows' executables: .exe, which install files leave implicit.
    if [[ $target == *-windows-* && $section == *bin && $rel != *.exe ]]; then rel="$rel.exe"; fi
    mkdir -p "$out/$(dirname "$rel")"
    cp -L "$file" "$out/$rel"
    case "$section" in
      bin | sbin | man) root="$section/" ;;
      share_root) root="share/" ;;
      *) root="$section/$package/" ;;
    esac
    entries[$section]+="  \"$rel\" {\"${rel#"$root"}\"}"$'\n'
  done < <(awk '
    /^[a-z_]+: \[/ { section = $1; sub(":", "", section) }
    section ~ /^(bin|sbin|share|share_root|etc|doc|man)$/ && match($0, /"[^"]+"/) {
      print section, substr($0, RSTART + 1, RLENGTH - 2)
    }
  ' "$install")
  for section in bin sbin share share_root etc doc man; do
    [[ -z "${entries[$section]:-}" ]] || printf '%s: [\n%s]\n' "$section" "${entries[$section]}"
  done >"$out/$package.install"
  unset entries
done
