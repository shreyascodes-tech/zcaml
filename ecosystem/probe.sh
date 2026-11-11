#!/usr/bin/env bash
# Builds one opam package with dune pkg, natively and for each target, as a
# project depending on it would: an executable linking its libraries (all of their
# modules: -linkall), run on the target. `run.sh` sets up the environment.
#
#   ecosystem/probe.sh <work-dir> <package>[<constraint>] [<library> | pps:<ppx> | !<target>]...
#
# Appends `<package> <stage> ok|fail|skip` lines to <work-dir>/results.tsv, stages:
# lock, native, then build:<target> and run:<target> for each of $TARGETS, but
# `build:<target> skip` for a !<target>, which the package doesn't support. The
# first failure stops the package (a target's build failure, only that target),
# its log is <work-dir>/<package>/<stage, with - for :>.log. `lock` fails when
# the lock file lacks a solution for a platform the package is built for, which
# `dune pkg lock`'s exit status doesn't say: it exits 0 with a partial solution.
#
# DUNE_JOBS is each dune build's -j (default 2, as probes share the machine).
# PROBE_LOCK_ONLY=1 stops after the lock, which warms the repositories.
set -uo pipefail

work="$1"
package_spec="$2"
package="${package_spec%%[<>=]*}"
constraint="${package_spec#"$package"}"
shift 2
libraries=()
ppxs=()
unsupported=" "
build_only=0
for spec in "$@"; do
  case "$spec" in
    pps:*) ppxs+=("${spec#pps:}") ;;
    !*) unsupported="$unsupported${spec#!} " ;;
    -) build_only=1 ;;
    *) libraries+=("$spec") ;;
  esac
done
if [[ $build_only -eq 0 && ${#libraries[@]} -eq 0 ]]; then
  libraries=("$package")
fi

dir="$work/$package"
rm -rf "$dir"
mkdir -p "$dir/bin"
cd "$dir"

depends="$package"
if [[ -n "$constraint" ]]; then
  operator="${constraint%%[0-9]*}"
  version="${constraint#"$operator"}"
  depends="($package ($operator $version))"
fi

cat >dune-project <<EOF
(lang dune 3.24)
(package (name probe) (allow_empty) (depends $depends))
EOF
cat >dune-workspace <<EOF
(lang dune 3.24)
$(cat "$work/repositories.dune")
EOF
{
  echo '(executable'
  echo ' (name main)'
  if [[ $build_only -eq 0 ]]; then echo " (libraries ${libraries[*]})"; fi
  if [[ ${#ppxs[@]} -gt 0 ]]; then echo " (preprocess (pps ${ppxs[*]}))"; fi
  echo ' (link_flags (-linkall)))'
} >bin/dune
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

# Whether the lock file solved for <target>'s platform. Its
# `solved_for_platforms` lists the ones it did solve, one
# `((arch ...) (os ...) ...)` each. Takes the target's triple, whose arch and os
# are opam's, as scripts/cross-env.sh's platform() writes them.
locked() {
  local target="$1" arch os
  case "$target" in
    aarch64-*) arch=arm64 ;;
    x86_64-*) arch=x86_64 ;;
    *) arch="${target%%-*}" ;;
  esac
  case "$target" in
    *-linux-*) os=linux ;;
    *-windows-*) os=win32 ;;
    *-macos-*) os=macos ;;
    *) os="${target#*-}"; os="${os%%-*}" ;;
  esac
  sed -n '/^(solved_for_platforms/,/^$/p' dune.lock/lock.dune |
    grep -oE '\((arch|os) [^)]+\)' |
    paste -d' ' - - |
    grep -qxF "(arch $arch) (os $os)"
}

# `dune pkg lock`, and that it solved for every platform the package is built
# for: a target it has no solution for is only a warning, and that target's
# build then fails with "lockdir does not contain a solution". Exported: `stage`
# runs it through `timeout`, a separate process.
lock() {
  dune pkg lock || return
  local target
  for target in "$@"; do
    locked "$target" || {
      echo "dune pkg lock solved no platform for $target" >&2
      return 1
    }
  done
}
export -f locked lock

if [[ "${PROBE_LOCK_ONLY:-}" == 1 ]]; then
  dune pkg lock >/dev/null 2>&1 || exit 0
  exit 0
fi
# The native platform, x86_64-linux-gnu, is cross-env.sh's, then each target's,
# but not a !<target>'s: the package isn't built for it, so it needn't lock.
lock_targets=(x86_64-linux-gnu)
for target in $TARGETS; do
  [[ "$unsupported" == *" $target "* ]] || lock_targets+=("$target")
done
stage lock bash -c 'lock "$@"' lock "${lock_targets[@]}" || exit 0

dune_jobs="${DUNE_JOBS:-2}"
stage native dune build -j "$dune_jobs" ./bin/main.exe || exit 0
for target in $TARGETS; do
  if [[ "$unsupported" == *" $target "* ]]; then
    printf '%s\t%s\t%s\n' "$package" "build:$target" skip | tee -a "$work/results.tsv"
    continue
  fi
  exe="_build/default.${target//-/_}/bin/main.exe" # run.sh's toolchain names
  stage "build:$target" dune build -j "$dune_jobs" -x "${target//-/_}" "./$exe" || continue
  read -ra runner <<<"$(runner "$target")"
  stage "run:$target" bash -c 'run "$@"' run "${runner[@]}" "$exe"
done
# The results are in results.tsv: run.sh goes on to the next package.
exit 0
