# Sourced: sets up cross-compiling dune pkg's packages with a zcaml release's
# toolchains, for ecosystem/run.sh and devtools/build.sh. Takes
#
#   $work        where it writes findlib.conf and repositories.dune
#   $toolchains  a toolchain per target, `target-<triple>`, for this machine
#                (x86_64-linux-gnu, whose own is the native one): a release's
#                `ocaml-<version>-host-x86_64-linux-gnu-target-<triple>.tar.zst`s
#   $dune_bin    zcaml's dune
#   TARGETS      the targets, besides this machine
#   OVERLAY      zcaml's overlay, default: this checkout's; empty: none
#   OVERLAYS     more opam repositories, ahead of it: `<name>=<url>`s
#
# repositories.dune is a dune-workspace's repositories and lock directory.

# The toolchains, as a findlib configuration: `-x <triple, with _ for ->` builds
# with target-<triple>'s (findlib's names can't have `-`). The native one is also
# first on PATH: the lock directory's `ocaml-system`.
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

# A target's platform, as the lock directory's solutions are for: opam's names.
platform() {
  case "$1" in
    x86_64-linux-gnu | x86_64-linux-musl) echo '((arch x86_64) (os linux))' ;;
    aarch64-linux-gnu | aarch64-linux-musl) echo '((arch arm64) (os linux))' ;;
    x86_64-windows-gnu) echo '((arch x86_64) (os win32) (sys-ocaml-arch x86_64) (sys-ocaml-cc cc) (sys-ocaml-libc msvc))' ;;
    x86_64-macos-none) echo '((arch x86_64) (os macos))' ;;
    aarch64-macos-none) echo '((arch arm64) (os macos))' ;;
    *) echo "error: no platform for $1" >&2; exit 1 ;;
  esac
}
platforms="$(for target in x86_64-linux-gnu $TARGETS; do platform "$target"; done | sort -u | tr '\n' ' ')"

# $OVERLAYS, zcaml's overlay, then dune's default repositories, at fixed commits:
# a build doesn't depend on when it ran.
zcaml_overlay="${OVERLAY-$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay" && pwd)}"
overlays=""
for overlay in ${OVERLAYS:-} ${zcaml_overlay:+"zcaml=file://$(cd "$zcaml_overlay" && pwd)"}; do
  printf '(repository\n (name %s)\n (url %s))\n' "${overlay%%=*}" "${overlay#*=}"
  overlays="$overlays ${overlay%%=*}"
done >"$work/repositories.dune"
cat >>"$work/repositories.dune" <<EOF2
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
 (repositories$overlays overlay-pinned relocatable-pinned upstream-pinned)
 (solver_env (sys-ocaml-version 5.5.1))
 (solve_for_platforms $platforms)
 (constraints (ocaml-system (= 5.5.1))))
EOF2
