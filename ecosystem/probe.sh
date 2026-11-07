#!/usr/bin/env bash
# Builds one opam package with dune pkg, natively and for each target, as a
# project depending on it would: an executable linking its libraries (all of their
# modules: -linkall), run on the target. `run.sh` sets up the environment.
#
#   ecosystem/probe.sh <work-dir> <package> [<library> | pps:<ppx> | !<target>]...
#
# Appends `<package> <stage> ok|fail|skip` lines to <work-dir>/results.tsv, stages:
# lock, native, then build:<target> and run:<target> for each of $TARGETS, but
# `build:<target> skip` for a !<target>, which the package doesn't support. The
# first failure stops the package (a target's build failure, only that target),
# its log is <work-dir>/<package>/<stage, with - for :>.log.
set -uo pipefail

work="$1"
package="$2"
shift 2
libraries=()
ppxs=()
unsupported=" "
for spec in "$@"; do
  case "$spec" in
    pps:*) ppxs+=("${spec#pps:}") ;;
    !*) unsupported="$unsupported${spec#!} " ;;
    *) libraries+=("$spec") ;;
  esac
done
[[ ${#libraries[@]} -gt 0 ]] || libraries=("$package")

dir="$work/$package"
rm -rf "$dir"
mkdir -p "$dir/bin"
cd "$dir"

cat >dune-project <<EOF
(lang dune 3.24)
(package (name probe) (allow_empty) (depends $package))
EOF
cat >dune-workspace <<EOF
(lang dune 3.24)
$(cat "$work/repositories.dune")
EOF
cat >bin/dune <<EOF
(executable
 (name main)
 (libraries ${libraries[*]})
 ${ppxs:+(preprocess (pps ${ppxs[*]}))}
 (link_flags (-linkall)))
EOF
echo 'let () = print_endline "ok"' >bin/main.ml

# Runs <stage>'s command, recording the result; `false` if it failed.
stage() {
  local name="$1"
  shift
  local result=ok
  timeout "${STAGE_TIMEOUT:-1800}" "$@" >"${name/:/-}.log" 2>&1 || result=fail
  printf '%s\t%s\t%s\n' "$package" "$name" "$result" | tee -a "$work/results.tsv"
  [[ $result == ok ]]
}

# What runs <target>'s executables here.
runner() {
  case "$1" in
    aarch64-linux-gnu) echo "qemu-aarch64 -L $AARCH64_LINUX_GNU_SYSROOT" ;;
    x86_64-windows-gnu) echo wine ;;
    *) echo "error: no way to run $1's executables" >&2; exit 1 ;;
  esac
}

# Runs an executable, which prints `ok`, not just exits 0, if it works. Exported:
# `stage` runs it through `timeout`, a separate process.
run() {
  local output
  output="$("$@")" || return
  printf '%s\n' "$output"
  [[ "${output%$'\r'}" == ok ]]
}
export -f run

stage lock dune pkg lock || exit 0
stage native dune build ./bin/main.exe || exit 0
for target in $TARGETS; do
  if [[ "$unsupported" == *" $target "* ]]; then
    printf '%s\t%s\t%s\n' "$package" "build:$target" skip | tee -a "$work/results.tsv"
    continue
  fi
  exe="_build/default.${target//-/_}/bin/main.exe" # run.sh's toolchain names
  stage "build:$target" dune build -x "${target//-/_}" "./$exe" || continue
  read -ra runner <<<"$(runner "$target")"
  stage "run:$target" bash -c 'run "$@"' run "${runner[@]}" "$exe"
done
