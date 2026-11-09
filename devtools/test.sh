#!/usr/bin/env bash
# Smoke-tests a dev tool build.sh built, for a target: ocamlformat formats code,
# ocamllsp answers an LSP initialize request.
#
#   devtools/test.sh <dir> <package> <version> [<runner>...]
#
# <dir> is build.sh's out/<target>. <runner> runs its executables, if they don't
# run here: `qemu-aarch64 -L <sysroot>`, `wine`, `arch -x86_64`.
set -euo pipefail

dir="$1"
package="$2"
version="$3"
shift 3

exe() {
  if [[ -f "$dir/bin/$1.exe" ]]; then echo "$dir/bin/$1.exe"; else echo "$dir/bin/$1"; fi
}

# An LSP message: a header, then the JSON.
message() {
  printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"
}

case "$package" in
  ocamlformat)
    got="$(printf 'let   f x=\n  x+1\n' | "$@" "$(exe ocamlformat)" --enable-outside-detected-project --impl - | tr -d '\r')"
    expected="let f x = x + 1"
    ;;
  ocaml-lsp-server)
    got="$({
      message '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
      sleep 5
      message '{"jsonrpc":"2.0","id":2,"method":"shutdown"}'
      sleep 1
      message '{"jsonrpc":"2.0","method":"exit"}'
    } | "$@" "$(exe ocamllsp)" 2>/dev/null | tr -d '\r' | grep -o '"serverInfo":{[^}]*}' || true)"
    expected="\"serverInfo\":{\"name\":\"ocamllsp\",\"version\":\"$version\"}"
    ;;
  *)
    echo "error: no test for $package" >&2
    exit 1
    ;;
esac

if [[ "$got" != "$expected" ]]; then
  echo "error: $package for $dir: '$got', expected '$expected'" >&2
  exit 1
fi
echo "ok: $package $version ($dir)"
