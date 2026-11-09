#!/usr/bin/env bash
# Writes overlay/'s binary packages of a devtools.yml release: one per host, of
# its archive, `<package>.<version>+zcaml.<revision>-<host>`. dune pkg's dev tools
# (`dune tools exec ocamllsp`, `dune fmt`) take them over building the tool:
# they're of the version asked for (`.ocamlformat`'s; ocamlformat's 0.29.0 takes
# 0.29.0+...), and sort above it.
#
#   devtools/overlay.sh <tag> [<SHA256SUMS>]
#
# <tag>: `<package>-v<version>-zcaml.<revision>`. Its SHA256SUMS, the archives'
# checksums, is the release's, by default.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo=shreyascodes-tech/zcaml
tag="$1"
if [[ ! "$tag" =~ ^(.+)-v(.+)-zcaml\.([0-9]+)$ ]]; then
  echo "error: '$tag' isn't <package>-v<version>-zcaml.<revision>" >&2
  exit 1
fi
package="${BASH_REMATCH[1]}"
version="${BASH_REMATCH[2]}"
revision="${BASH_REMATCH[3]}"
read -r ocaml license homepage < <(awk -v p="$package" -v v="$version" '$1 == p && $2 == v { print $3, $4, $5 }' "$here/devtools.txt")
if [[ -z "${ocaml:-}" ]]; then
  echo "error: $package $version isn't in devtools.txt" >&2
  exit 1
fi
sums="${2:-}"
if [[ -z "$sums" ]]; then
  sums="$(mktemp)"
  trap 'rm -f "$sums"' EXIT
  gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --output "$sums" --clobber
fi

# Where a host's build runs, in opam's variables: musl's on Alpine.
available() {
  case "$1" in
    x86_64-linux-gnu) echo 'os = "linux" & arch = "x86_64" & os-distribution != "alpine"' ;;
    aarch64-linux-gnu) echo 'os = "linux" & arch = "arm64" & os-distribution != "alpine"' ;;
    x86_64-linux-musl) echo 'os = "linux" & arch = "x86_64" & os-distribution = "alpine"' ;;
    aarch64-linux-musl) echo 'os = "linux" & arch = "arm64" & os-distribution = "alpine"' ;;
    x86_64-windows-gnu) echo 'os = "win32" & arch = "x86_64"' ;;
    x86_64-macos-none) echo 'os = "macos" & arch = "x86_64"' ;;
    aarch64-macos-none) echo 'os = "macos" & arch = "arm64"' ;;
    *) echo "error: no opam platform for $1" >&2; exit 1 ;;
  esac
}

# The OCaml it's for, a release (5.5): its patch releases.
for_ocaml=""
if [[ $ocaml != - ]]; then
  for_ocaml=">= \"$ocaml\" & < \"${ocaml%.*}.$((${ocaml#*.} + 1))~\""
fi

prefix="$package-$version-zcaml.$revision-"
while read -r sha256 archive; do
  archive="${archive#\*}"
  [[ "$archive" == "$prefix"*.tar.gz ]] || continue
  host="${archive#"$prefix"}"
  host="${host%.tar.gz}"
  dir="$here/../overlay/packages/$package/$package.$version+zcaml.$revision-$host"
  mkdir -p "$dir"
  {
    echo 'opam-version: "2.0"'
    echo "synopsis: \"$package $version, pre-built for $host${for_ocaml:+, for OCaml $ocaml}\""
    echo 'maintainer: "Shreyas Mididoddi <me@shreyascodes.tech>"'
    echo "license: \"$license\""
    echo "homepage: \"$homepage\""
    echo "available: $(available "$host")"
    # As a dependency, not a conflict: a binary package has no other, so a
    # conflict with `ocaml` would hold with any compiler.
    [[ -z "$for_ocaml" ]] || echo "depends: [ \"ocaml\" {$for_ocaml} ]"
    echo 'url {'
    echo "  src: \"https://github.com/$repo/releases/download/$tag/$archive\""
    echo "  checksum: \"sha256=$sha256\""
    echo '}'
  } >"$dir/opam"
  echo "$dir"
done <"$sums"
