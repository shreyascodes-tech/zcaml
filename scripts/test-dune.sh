#!/usr/bin/env bash
# Smoke-tests a dune binary built by `zig build -Docaml dune`, without an OCaml
# compiler: its version, and creating a project (files and processes).
#
#   scripts/test-dune.sh <dune-exe> <expected-version> [<runner>...]
#
# <runner> runs it, if it doesn't run here: `qemu-aarch64 -L <sysroot>`, `wine`,
# `arch -x86_64`.
set -euo pipefail

exe="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
expected="$2"
shift 2

got="$("$@" "$exe" --version | tr -d '\r')"
if [[ "$got" != "$expected" ]]; then
  echo "error: $exe --version: '$got', expected '$expected'" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$work" && "$@" "$exe" init project smoke >/dev/null)
test -f "$work/smoke/dune-project" && test -f "$work/smoke/bin/main.ml"
echo "ok: $exe ($got)"
