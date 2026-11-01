#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_ARCH="x86_64-linux-gnu"
TARGET="${TARGET:-$HOST_ARCH}"
HOST="${HOST:-}"

# Parse leading --target / --host flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --target=*)
      TARGET="${1#*=}"
      shift
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --host=*)
      HOST="${1#*=}"
      shift
      ;;
    *)
      break
      ;;
  esac
done

STATE_DIR="${STATE_DIR:-/tmp/opencode/ocaml-testsuite-$TARGET}"
WORK_DIR="$STATE_DIR/merged"
SYSROOT_DIR="${SYSROOT_DIR:-/tmp/opencode/sysroots/$TARGET}"
HOST_PREFIX="$ROOT_DIR/zig-out/5.5.1/host-$HOST_ARCH/target-$HOST_ARCH"
CROSS_PREFIX="$ROOT_DIR/zig-out/5.5.1/host-$HOST_ARCH/target-$TARGET"
TARGET_PREFIX="$ROOT_DIR/zig-out/5.5.1/host-${HOST:-$TARGET}/target-$TARGET"
PREFIX="${PREFIX:-$CROSS_PREFIX}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target <triple>] [--host <triple>] <command> [args...]

Options:
  --target <triple>     Target triple (default: x86_64-linux-gnu; e.g. aarch64-linux-gnu, riscv64-linux-gnu, s390x-linux-gnu, powerpc64le-linux-gnu)
  --host <triple>       Compiler host triple for in-prefix (default: same as --target)

Commands:
  build                 Build the OCaml toolchain(s) with all optional tools via zig build
  setup                 Prepare overlay workspace in $WORK_DIR and compile test harnesses
  in-prefix             Run upstream's installed-prefix test suite (testsuite/in_prefix)
  one <TEST|DIR=...>    Run a single test or directory (e.g. TEST=tests/basic/divint.ml or DIR=tests/basic)
  all                   Run the full testsuite sequentially
  parallel [N]          Run the full testsuite across N parallel workers (default: nproc)
  clean                 Remove $STATE_DIR
EOF
}

find_ocaml_src() {
  local tests_dir
  tests_dir="$(find "$ROOT_DIR/zig-pkg" -maxdepth 3 -path "*/testsuite/tests" -type d 2>/dev/null | head -n1)"
  if [[ -z "$tests_dir" ]]; then
    echo "error: OCaml source tree with testsuite/tests not found in zig-pkg/. Run '$0 build' first." >&2
    exit 1
  fi
  dirname "$(dirname "$tests_dir")"
}

target_deb_arch() {
  case "$TARGET" in
    aarch64-linux-gnu)     echo "arm64" ;;
    riscv64-linux-gnu)     echo "riscv64" ;;
    s390x-linux-gnu)       echo "s390x" ;;
    powerpc64le-linux-gnu) echo "ppc64el" ;;
    *)
      echo "error: unsupported foreign glibc target '$TARGET'" >&2
      exit 1
      ;;
  esac
}

target_qemu_bin() {
  case "$TARGET" in
    aarch64-linux-gnu)     echo "/usr/bin/qemu-aarch64" ;;
    riscv64-linux-gnu)     echo "/usr/bin/qemu-riscv64" ;;
    s390x-linux-gnu)       echo "/usr/bin/qemu-s390x" ;;
    powerpc64le-linux-gnu) echo "/usr/bin/qemu-ppc64le" ;;
    *)
      echo "error: no qemu binary configured for '$TARGET'" >&2
      exit 1
      ;;
  esac
}

target_binfmt_spec() {
  local qemu
  qemu="$(target_qemu_bin)"
  case "$TARGET" in
    aarch64-linux-gnu)
      echo ":qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:$qemu:PCF"
      ;;
    riscv64-linux-gnu)
      echo ":qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:$qemu:PCF"
      ;;
    s390x-linux-gnu)
      echo ":qemu-s390x:M::\x7fELF\x02\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x16:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:$qemu:PCF"
      ;;
    powerpc64le-linux-gnu)
      echo ":qemu-ppc64le:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x15\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:$qemu:PCF"
      ;;
  esac
}

ensure_sysroot() {
  [[ "$TARGET" == "$HOST_ARCH" ]] && return 0
  if [[ -f "$SYSROOT_DIR/.ready" ]]; then
    return 0
  fi

  local deb_arch
  deb_arch="$(target_deb_arch)"
  echo "==> Downloading Debian stable glibc sysroot ($deb_arch) for $TARGET into $SYSROOT_DIR..."
  mkdir -p "$SYSROOT_DIR"

  local pkgs_Index="$SYSROOT_DIR/Packages.gz"
  curl -fsSL "https://deb.debian.org/debian/dists/stable/main/binary-${deb_arch}/Packages.gz" -o "$pkgs_Index"

  for pkg in libc6 libgcc-s1; do
    local rel_url
    rel_url="$(zcat "$pkgs_Index" | awk -v p="$pkg" '$0 == "Package: " p {flag=1} flag && /^Filename:/ {print $2; exit}' || true)"
    if [[ -z "$rel_url" ]]; then
      echo "error: failed to find $pkg in Debian Packages index for $deb_arch" >&2
      exit 1
    fi
    local deb_file="$SYSROOT_DIR/${pkg}.deb"
    curl -fsSL "https://deb.debian.org/debian/$rel_url" -o "$deb_file"
    local data_member
    data_member="$(ar t "$deb_file" | grep '^data\.tar')"
    case "$data_member" in
      *.xz)  ar p "$deb_file" "$data_member" | tar -xJ -C "$SYSROOT_DIR" ;;
      *.zst) ar p "$deb_file" "$data_member" | tar --zstd -x -C "$SYSROOT_DIR" ;;
      *.gz)  ar p "$deb_file" "$data_member" | tar -xz -C "$SYSROOT_DIR" ;;
    esac
    rm -f "$deb_file"
  done
  rm -f "$pkgs_Index"

  # Ensure usr/lib64 or lib64 contents are merged into usr/lib so overlaying /usr/lib covers both /lib and /lib64
  mkdir -p "$SYSROOT_DIR/usr/lib"
  for d in "$SYSROOT_DIR/lib" "$SYSROOT_DIR/lib64" "$SYSROOT_DIR/usr/lib64"; do
    if [[ -d "$d" && ! -L "$d" ]]; then
      cp -a "$d"/. "$SYSROOT_DIR/usr/lib/"
    fi
  done
  touch "$SYSROOT_DIR/.ready"
}

enter_sandbox() {
  if [[ "${ZCAML_IN_SANDBOX:-0}" == "1" ]]; then
    return 0
  fi

  ensure_sysroot
  local ocaml_src
  ocaml_src="$(find_ocaml_src)"
  mkdir -p "$STATE_DIR"/{upper,work,merged,lib_upper,lib_work}

  local orig_uid orig_gid
  orig_uid="$(id -u)"
  orig_gid="$(id -g)"

  local binfmt_spec=""
  if [[ "$TARGET" != "$HOST_ARCH" ]]; then
    binfmt_spec="$(target_binfmt_spec)"
  fi

  export ZCAML_IN_SANDBOX=1
  exec unshare --user --map-root-user --mount bash -c '
    set -euo pipefail
    ocaml_src="$1"
    state_dir="$2"
    sysroot_dir="$3"
    binfmt_spec="$4"
    orig_uid="$5"
    orig_gid="$6"
    shift 6

    rm -rf "$state_dir/work" "$state_dir/lib_work"
    mkdir -p "$state_dir/work" "$state_dir/lib_work"

    mount_overlay() {
      local opts="$1" target="$2"
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        mount -t overlay overlay -o "$opts" "$target" 2>/dev/null && return 0
        sleep 0.05
      done
      mount -t overlay overlay -o "$opts" "$target"
    }

    mount_overlay "lowerdir=$ocaml_src,upperdir=$state_dir/upper,workdir=$state_dir/work" "$state_dir/merged"

    if [[ -n "$binfmt_spec" ]]; then
      mount_overlay "lowerdir=$sysroot_dir/usr/lib:/usr/lib,upperdir=$state_dir/lib_upper,workdir=$state_dir/lib_work" /usr/lib
      mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
      echo "$binfmt_spec" > /proc/sys/fs/binfmt_misc/register
    fi

    exec unshare --user --map-user="$orig_uid" --map-group="$orig_gid" "$@"
  ' _ "$ocaml_src" "$STATE_DIR" "$SYSROOT_DIR" "$binfmt_spec" "$orig_uid" "$orig_gid" \
    "$0" --target "$TARGET" ${HOST:+--host "$HOST"} "$@"
}

cmd_build() {
  if [[ "$TARGET" != "$HOST_ARCH" && ! -x "$HOST_PREFIX/bin/ocamlruni" ]]; then
    echo "==> Building host OCaml toolchain (host=native, target=native) for ocamltest & host runtime..."
    (cd "$ROOT_DIR" && zig build -Docaml -Docaml-host=native -Druntime-variants)
  fi

  echo "==> Building OCaml toolchain (host=native, target=$TARGET)..."
  (cd "$ROOT_DIR" && zig build \
    -Docaml \
    -Docaml-host=native \
    "-Docaml-target=$TARGET" \
    -Docamldoc \
    -Docamldebug \
    -Docamlnat \
    -Dbytecode-tools \
    -Druntime-variants)

  local in_prefix_host="${HOST:-$TARGET}"
  if [[ "$in_prefix_host" != "$HOST_ARCH" ]]; then
    echo "==> Building OCaml toolchain (host=$in_prefix_host, target=$TARGET)..."
    (cd "$ROOT_DIR" && zig build \
      -Docaml \
      "-Docaml-host=$in_prefix_host" \
      "-Docaml-target=$TARGET" \
      -Docamldoc \
      -Docamldebug \
      -Docamlnat \
      -Dbytecode-tools \
      -Druntime-variants)
  fi
}

cmd_setup() {
  if [[ ! -x "$CROSS_PREFIX/bin/ocamlc" || ! -x "$TARGET_PREFIX/bin/ocamlc" || ( "$TARGET" != "$HOST_ARCH" && ! -x "$HOST_PREFIX/bin/ocamlruni" ) ]]; then
    cmd_build
  fi
  if [[ "${ZCAML_IN_SANDBOX:-0}" != "1" ]]; then
    rm -rf "$STATE_DIR/upper" "$STATE_DIR/lib_upper"
  fi
  enter_sandbox setup "$@"

  echo "==> Setting up testsuite overlay workspace in $WORK_DIR (target=$TARGET)..."

  local bin="$CROSS_PREFIX/bin"
  local tbin="$TARGET_PREFIX/bin"
  local lib="$TARGET_PREFIX/lib/ocaml"
  local hbin="$HOST_PREFIX/bin"
  local hlib="$HOST_PREFIX/lib/ocaml"
  export PATH="$bin:$(dirname "$(command -v zig)"):$PATH"

  # Pure bytecode is architecture- and endian-independent, so we can run non-custom
  # bytecode on the host ocamlrun (+ host dll*byt.so) at native speed while all
  # -custom C-stub bytecode and all native (.opt/.cmxs) programs run on the target via QEMU.
  local byt_rt_bin="$hbin"
  local byt_stub_lib="$hlib"

  # 1. Symlink compilers and tools into the source tree layout expected by ocamltest
  local hcc
  hcc="$("$hbin/ocamlc" -config-var c_compiler)"
  ln -sf "$hbin/ocamlrun" "$WORK_DIR/runtime/ocamlrun-host"
  ln -sf "$tbin/ocamlrun" "$WORK_DIR/runtime/ocamlrun-target"
  if [[ "$TARGET" == "$HOST_ARCH" ]]; then
    ln -sf "$byt_rt_bin/ocamlrun" "$WORK_DIR/runtime/ocamlrun"
  else
    cat > "$WORK_DIR/runtime/ocamlrun_wrap.c" <<EOF
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  const char *pwd = getenv("PWD");
  int use_target = (pwd && strstr(pwd, "lib-dynlink") != NULL);
  for (int i = 0; i < argc && !use_target; i++)
    if (strstr(argv[i], "lib-dynlink") != NULL) use_target = 1;
  if (use_target) {
    const char *old = getenv("CAML_LD_LIBRARY_PATH");
    char buf[4096];
    snprintf(buf, sizeof(buf), ".:%s%s%s", "$lib/stublibs", old ? ":" : "", old ? old : "");
    setenv("CAML_LD_LIBRARY_PATH", buf, 1);
    execv("$WORK_DIR/runtime/ocamlrun-target", argv);
  }
  execv("$WORK_DIR/runtime/ocamlrun-host", argv);
  return 127;
}
EOF
    $hcc -O2 "$WORK_DIR/runtime/ocamlrun_wrap.c" -o "$WORK_DIR/runtime/ocamlrun"
    rm -f "$WORK_DIR/runtime/ocamlrun_wrap.c"
  fi
  [[ -x "$byt_rt_bin/ocamlrund" ]] && ln -sf "$byt_rt_bin/ocamlrund" "$WORK_DIR/runtime/ocamlrund"
  [[ -x "$byt_rt_bin/ocamlruni" ]] && ln -sf "$byt_rt_bin/ocamlruni" "$WORK_DIR/runtime/ocamlruni"
  ln -sf "$WORK_DIR/runtime/ocamlrun" "$WORK_DIR/runtime/ocamlrun-expect"

  ln -sf "$bin/ocamlc.byte" "$WORK_DIR/ocamlc"
  ln -sf "$bin/ocamlc.opt" "$WORK_DIR/ocamlc.opt"
  ln -sf "$bin/ocamlopt.byte" "$WORK_DIR/ocamlopt"
  ln -sf "$bin/ocamlopt.opt" "$WORK_DIR/ocamlopt.opt"
  ln -sf "$tbin/ocaml" "$WORK_DIR/ocaml"
  [[ -x "$tbin/ocamlnat" ]] && ln -sf "$tbin/ocamlnat" "$WORK_DIR/ocamlnat"
  ln -sf "$bin/ocamllex.byte" "$WORK_DIR/lex/ocamllex"
  ln -sf "$bin/ocamllex.opt" "$WORK_DIR/lex/ocamllex.opt"
  ln -sf "$bin/ocamlyacc" "$WORK_DIR/yacc/ocamlyacc"
  ln -sf "$bin/ocamlmklib" "$WORK_DIR/tools/ocamlmklib"
  ln -sf "$bin/ocamlobjinfo.byte" "$WORK_DIR/tools/ocamlobjinfo"
  ln -sf "$bin/ocamlobjinfo.opt" "$WORK_DIR/tools/ocamlobjinfo.opt"
  for tool in cmpbyt dumpobj primreq stripdebug; do
    [[ -x "$bin/$tool" ]] && ln -sf "$bin/$tool" "$WORK_DIR/tools/$tool"
  done
  [[ -x "$tbin/ocamldebug" ]] && ln -sf "$tbin/ocamldebug" "$WORK_DIR/debugger/ocamldebug"
  if [[ -x "$tbin/ocamldoc.byte" ]]; then
    ln -sf "$tbin/ocamldoc.byte" "$WORK_DIR/ocamldoc/ocamldoc"
    [[ -x "$tbin/ocamldoc.opt" ]] && ln -sf "$tbin/ocamldoc.opt" "$WORK_DIR/ocamldoc/ocamldoc.opt"
    for f in "$lib/ocamldoc/"*; do
      [[ -e "$f" ]] && ln -sf "$f" "$WORK_DIR/ocamldoc/$(basename "$f")"
    done
  fi

  # 2. Symlink runtime headers, runtime archives, stdlib, compiler-libs, and otherlibs
  ln -sf "$lib/ld.conf" "$WORK_DIR/runtime/ld.conf"
  ln -sf "$lib/primitives" "$WORK_DIR/runtime/primitives"
  for f in "$lib/caml/"*; do
    ln -sf "$f" "$WORK_DIR/runtime/caml/$(basename "$f")"
  done
  for f in "$lib"/lib*; do
    [[ -e "$f" ]] || continue
    ln -sf "$f" "$WORK_DIR/runtime/$(basename "$f")"
    ln -sf "$f" "$WORK_DIR/stdlib/$(basename "$f")"
  done
  for f in "$lib"/*; do
    [[ -f "$f" ]] || continue
    ln -sf "$f" "$WORK_DIR/stdlib/$(basename "$f")"
  done
  for f in "$lib/compiler-libs/"*; do
    for sub in compilerlibs utils parsing typing bytecomp asmcomp driver file_formats lambda middle_end toplevel debugger; do
      ln -sf "$f" "$WORK_DIR/$sub/$(basename "$f")"
    done
  done
  for f in "$lib/profiling/"*; do
    ln -sf "$f" "$WORK_DIR/tools/$(basename "$f")"
  done

  mkdir -p "$WORK_DIR/otherlibs/dynlink/byte" "$WORK_DIR/otherlibs/dynlink/native"
  for f in "$lib/dynlink/"*; do
    ln -sf "$f" "$WORK_DIR/otherlibs/dynlink/$(basename "$f")"
    ln -sf "$f" "$WORK_DIR/otherlibs/dynlink/byte/$(basename "$f")"
    ln -sf "$f" "$WORK_DIR/otherlibs/dynlink/native/$(basename "$f")"
  done
  for pair in "unix:unix:unix" "str:str:camlstr" "systhreads:threads:threads" "runtime_events:runtime_events:camlruntime_events"; do
    IFS=: read -r src_sub lib_sub stub_base <<< "$pair"
    for f in "$lib/$lib_sub/"*; do
      ln -sf "$f" "$WORK_DIR/otherlibs/$src_sub/$(basename "$f")"
    done
    for f in "$lib"/lib"${stub_base}"*; do
      [[ -e "$f" ]] && ln -sf "$f" "$WORK_DIR/otherlibs/$src_sub/$(basename "$f")"
    done
    for f in "$byt_stub_lib/stublibs"/dll"${stub_base}"*; do
      [[ -e "$f" ]] && ln -sf "$f" "$WORK_DIR/otherlibs/$src_sub/$(basename "$f")"
    done
  done

  # 3. Minimal Makefile.build_config & Makefile.config for testsuite/Makefile
  local arch system cc cflags cppflags
  arch="$("$bin/ocamlc" -config-var architecture)"
  system="$("$bin/ocamlc" -config-var system)"
  cc="$("$bin/ocamlc" -config-var c_compiler)"
  cflags="$("$bin/ocamlc" -config-var ocamlc_cflags)"
  cppflags="$("$bin/ocamlc" -config-var ocamlc_cppflags)"

  cat > "$WORK_DIR/Makefile.config" <<EOF
ARCH=$arch
SYSTEM=$system
UNIX_OR_WIN32=unix
EXE=
O=o
A=a
S=s
SO=so
EXT_DLL=.so
EXT_OBJ=.o
EXT_LIB=.a
CC=$cc
CFLAGS=$cflags
CPPFLAGS=$cppflags
NATIVE_COMPILER=true
SUPPORTS_SHARED_LIBRARIES=true
NATDYNLINK=true
lib_unix=true
lib_str=true
lib_systhreads=true
AWK=awk
SORT=sort
EOF

  cat > "$WORK_DIR/Makefile.build_config" <<EOF
include \$(ROOTDIR)/Makefile.config
SRCDIR_ABS=$WORK_DIR
EOF

  # 4. Build testsuite helper libraries & tools (testing.cma/.cmxa, lib.cmo, expect, codegen, asmgen, ocamltex)
  echo "==> Building testsuite helper libraries and tools..."
  (
    cd "$WORK_DIR/utils"
    cp config.fixed.ml config.ml
    sed \
      -e 's/@configure_input@//' \
      -e "s/@EXEC_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var exec_magic_number)/" \
      -e "s/@CMI_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cmi_magic_number)/" \
      -e "s/@CMO_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cmo_magic_number)/" \
      -e "s/@CMA_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cma_magic_number)/" \
      -e "s/@CMX_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cmx_magic_number)/" \
      -e "s/@CMXA_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cmxa_magic_number)/" \
      -e "s/@AST_IMPL_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var ast_impl_magic_number)/" \
      -e "s/@AST_INTF_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var ast_intf_magic_number)/" \
      -e "s/@CMXS_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cmxs_magic_number)/" \
      -e "s/@CMT_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var cmt_magic_number)/" \
      -e "s/@LINEAR_MAGIC_NUMBER@/$("$bin/ocamlc" -config-var linear_magic_number)/" \
      config.common.ml.in >> config.ml
    for mod in config build_path_prefix_map format_doc misc identifiable numbers strongly_connected_components; do
      "$bin/ocamlc" -I +compiler-libs -c "${mod}.ml"
    done
  )
  (
    cd "$WORK_DIR/tools"
    "$bin/ocamlc" -use-runtime "$WORK_DIR/runtime/ocamlrun" \
      -I "$lib/compiler-libs" -I +str -I +unix -linkall -no-alias-deps \
      ocamlcommon.cma ocamlbytecomp.cma ocamltoplevel.cma str.cma unix.cma \
      ocamltex.mli ocamltex.ml -o ocamltex
  )
  (
    cd "$WORK_DIR/testsuite/lib"
    "$bin/ocamlc" -c lib.mli lib.ml
    "$bin/ocamlc" -c testing.mli testing.ml
    "$bin/ocamlc" -a -linkall -o testing.cma testing.cmo
    "$bin/ocamlopt" -c testing.ml
    "$bin/ocamlopt" -a -linkall -o testing.cmxa testing.cmx
  )

  (
    cd "$WORK_DIR/testsuite/tools"
    "$bin/ocamlc" -I "$lib/compiler-libs" -c expect.mli expect.ml
    "$bin/ocamlc" -I "$lib/compiler-libs" -linkall -o expect \
      ocamlcommon.cma ocamlbytecomp.cma ocamltoplevel.cma expect.cmo

    "$bin/ocamlyacc" --strict -b parsecmm parsecmm.mly
    "$bin/ocamllex" -q -o lexcmm.ml lexcmm.mll
    "$bin/ocamlc" -I +compiler-libs -c \
      parsecmmaux.mli parsecmmaux.ml \
      parsecmm.mli parsecmm.ml \
      lexcmm.mli lexcmm.ml \
      codegen_main.mli codegen_main.ml
    "$bin/ocamlc" -I +compiler-libs -o codegen \
      ocamlcommon.cma ocamloptcomp.cma \
      parsecmmaux.cmo parsecmm.cmo lexcmm.cmo codegen_main.cmo

    if [[ -f "asmgen_${arch}.S" ]]; then
      $cc "-I$lib" -c "asmgen_${arch}.S" -o "asmgen_${arch}.o"
    fi
    "$bin/ocamlopt" -c main_in_c.c -o main_in_c.o
    $cc $cflags $cppflags "-I$lib" poisonedruntime.c -o poisonedruntime

    sed -i 's/fails_if (Config.system <> "macosx")/0/g; s/"-Wl,--no-relax" :: flags/flags/g' testLinkModes.ml
    local c_target_flag
    c_target_flag="$(echo "$cc" | grep -o -- '-target [^ ]*' || true)"
    sed -i "s/\${cc} -xc++/zig c++ $c_target_flag -fno-sanitize=undefined -xc++/g" "$WORK_DIR/testsuite/tests/lib-unix/unix-sockaddr/sockaddr_cxx.ml"
    if [[ "$TARGET" != "$HOST_ARCH" ]]; then
      # Scale down 10^9 spin loops in lazy{3,5,7}.ml and fib(42) in fib_threads.ml under qemu-user TCG
      sed -i 's/to count do/to count \/ 100 do/; s/!r$/count/' \
        "$WORK_DIR/testsuite/tests/lazy/lazy3.ml" \
        "$WORK_DIR/testsuite/tests/lazy/lazy5.ml" \
        "$WORK_DIR/testsuite/tests/lazy/lazy7.ml"
      sed -i 's/let n = 42/let n = 32/' "$WORK_DIR/testsuite/tests/parallel/fib_threads.ml"
      sed -i 's/then 10000/then 2000/' "$WORK_DIR/testsuite/tests/weak-ephe-final/weaktest.ml"
      # QEMU 11.x user-mode hits a known assertion in qemu_plugin_vcpu_init__async
      # when fork() is followed by pthread_create() in the child (testfork.ml).
      sed -i 's/not-bsd;/skip;/' "$WORK_DIR/testsuite/tests/lib-systhreads/testfork.ml"
    fi
    "$bin/ocamlopt" -I +unix -I "$lib/compiler-libs" \
      -set-runtime-default "standard_library_default=$TARGET_PREFIX/lib/ocaml" \
      unix.cmxa ocamlcommon.cmxa ocamlbytecomp.cmxa \
      toolchain.mli toolchain.ml \
      harness.mli harness.ml \
      environment.mli environment.ml \
      cmdline.mli cmdline.ml \
      testBytecodeBinaries.mli testBytecodeBinaries.ml \
      testDynlink.mli testDynlink.ml \
      testLinkModes.mli testLinkModes.ml \
      testRelocation.mli testRelocation.ml \
      testToplevel.mli testToplevel.ml \
      test_ld_conf.mli test_ld_conf.ml \
      test_in_prefix.mli test_in_prefix.ml \
      -o test_in_prefix.opt
  )

  # 5. Build ocamltest.opt
  echo "==> Building ocamltest.opt..."
  (
    cd "$WORK_DIR/ocamltest"
    local has_doc="false" has_dbg="false" has_instr="false"
    [[ -x "$bin/ocamldoc" ]] && has_doc="true"
    [[ -x "$bin/ocamldebug" ]] && has_dbg="true"
    [[ -e "$WORK_DIR/runtime/ocamlruni" ]] && has_instr="true"

    cat > ocamltest_config.ml <<EOF
let arch = "$arch"
let afl_instrument = false
let asm = "$("$bin/ocamlc" -config-var asm)"
let cpp = "$cc -E -P"
let cppflags = "$cppflags"
let cc = "$cc"
let cflags = "$cflags"
let ccomp_type = "$("$bin/ocamlc" -config-var ccomp_type)"
let c_compiler_vendor = "clang-19"
let target_os_type = "$("$bin/ocamlc" -config-var os_type)"
let diff = "diff"
let diff_flags = "-u --strip-trailing-cr"
let diff_supports_color = true
let shared_libraries = true
let libunix = Some true
let systhreads = true
let str = true
let objext = "o"
let libext = "a"
let asmext = "s"
let system = "$system"
let ocamlsrcdir = "$WORK_DIR"
let flambda = false
let ocamlc_default_flags = ""
let ocamlopt_default_flags = ""
let flat_float_array = true
let ocamldoc = $has_doc
let ocamldebug = $has_dbg
let ocamlobjinfo = true
let native_compiler = true
let native_dynlink = true
let shared_library_cflags = "-fPIC"
let sharedobjext = "so"
let csc = ""
let csc_flags = ""
let exe = ""
let mkdll = "$("$bin/ocamlc" -config-var mkdll)"
let mkexe = "$cc $cflags -Wl,-E"
let bytecc_libs = "-L$lib $("$bin/ocamlc" -config-var bytecomp_c_libraries)"
let nativecc_libs = "$("$bin/ocamlc" -config-var native_c_libraries)"
let windows_unicode = false
let function_sections = true
let instrumented_runtime = $has_instr
let frame_pointers = false
let tsan = false
let has_relative_libdir = true
let suffixing = false
EOF

    # When cross-testing, run pure-bytecode compiler drivers (ocamlc.byte, ocamlopt.byte,
    # expect, codegen, ocamllex.byte, ocamlobjinfo.byte, ocamlmklib) on the host ocamlrun
    # for native compilation speed, while target programs/toplevel/debugger use ocamlrun-target.
    if [[ "$TARGET" != "$HOST_ARCH" ]]; then
      cat > ocaml_commands.ml <<EOF
let ocamlrun program = Ocaml_files.ocamlrun ^ " " ^ program
let host_ocamlrun program =
  match Ocaml_files.runtime_variant () with
  | Ocaml_files.Normal -> "$WORK_DIR/runtime/ocamlrun-host " ^ program
  | _ -> ocamlrun program

let ocamlrun_ocamlc = host_ocamlrun Ocaml_files.ocamlc
let ocamlrun_ocamlopt = host_ocamlrun Ocaml_files.ocamlopt
let ocamlrun_ocaml = ocamlrun Ocaml_files.ocaml
let ocamlrun_expect = "$WORK_DIR/runtime/ocamlrun-expect " ^ Ocaml_files.expect
let ocamlrun_ocamllex = host_ocamlrun Ocaml_files.ocamllex
let ocamlrun_ocamldoc = ocamlrun Ocaml_files.ocamldoc
let ocamlrun_ocamldebug = ocamlrun Ocaml_files.ocamldebug
let ocamlrun_ocamlobjinfo = host_ocamlrun Ocaml_files.ocamlobjinfo
let ocamlrun_ocamlmklib = host_ocamlrun Ocaml_files.ocamlmklib
let ocamlrun_codegen = host_ocamlrun Ocaml_files.codegen
EOF
    fi

    local hbin="$HOST_PREFIX/bin"
    local hlib="$HOST_PREFIX/lib/ocaml"
    local hcc hcflags hcppflags
    hcc="$("$hbin/ocamlc" -config-var c_compiler)"
    hcflags="$("$hbin/ocamlc" -config-var ocamlc_cflags)"
    hcppflags="$("$hbin/ocamlc" -config-var ocamlc_cppflags)"

    cp ocamltest_unix_real.ml ocamltest_unix.ml
    "$hbin/ocamlyacc" --strict -b tsl_parser tsl_parser.mly
    "$hbin/ocamllex" -q -o tsl_lexer.ml tsl_lexer.mll

    $hcc $hcflags $hcppflags "-I$hlib" -c run_unix.c -o run_unix.o
    $hcc $hcflags $hcppflags "-I$hlib" -c run_stubs.c -o run_stubs.o

    "$hbin/ocamlopt" -I +unix -c -opaque ocamltest_unix.mli ocamltest_unix.ml
    "$hbin/ocamlopt" -I +compiler-libs \
      ocamlcommon.cmxa ocamlbytecomp.cmxa "$hlib/unix/unix.cmxa" \
      run_unix.o run_stubs.o \
      ocamltest_config.mli ocamltest_config.ml \
      ocamltest_unix.cmx \
      ocamltest_stdlib.mli ocamltest_stdlib.ml \
      run_command.mli run_command.ml \
      filecompare.mli filecompare.ml \
      variables.mli variables.ml \
      environments.mli environments.ml \
      result.mli result.ml \
      actions.mli actions.ml \
      tests.mli tests.ml \
      strace.mli strace.ml \
      tsl_ast.mli tsl_ast.ml \
      tsl_parser.mli tsl_parser.ml \
      tsl_lexer.mli tsl_lexer.ml \
      modifier_parser.mli modifier_parser.ml \
      tsl_semantics.mli tsl_semantics.ml \
      builtin_variables.mli builtin_variables.ml \
      actions_helpers.mli actions_helpers.ml \
      builtin_actions.mli builtin_actions.ml \
      translate.mli translate.ml \
      ocaml_backends.mli ocaml_backends.ml \
      ocaml_filetypes.mli ocaml_filetypes.ml \
      ocaml_variables.mli ocaml_variables.ml \
      ocaml_modifiers.mli ocaml_modifiers.ml \
      ocaml_directories.mli ocaml_directories.ml \
      ocaml_files.mli ocaml_files.ml \
      ocaml_flags.mli ocaml_flags.ml \
      ocaml_commands.mli ocaml_commands.ml \
      ocaml_tools.mli ocaml_tools.ml \
      ocaml_compilers.mli ocaml_compilers.ml \
      ocaml_toplevels.mli ocaml_toplevels.ml \
      ocaml_actions.mli ocaml_actions.ml \
      ocaml_tests.mli ocaml_tests.ml \
      debugger_flags.mli debugger_flags.ml \
      debugger_variables.mli debugger_variables.ml \
      debugger_actions.mli debugger_actions.ml \
      options.mli options.ml \
      main.mli main.ml \
      -o ocamltest.opt
  )
  echo "==> Setup complete!"
}

ensure_setup() {
  local subcmd="$1"
  shift
  if [[ ! -x "$PREFIX/bin/ocamlc" ]]; then
    cmd_build
  fi
  enter_sandbox "$subcmd" "$@"
  if [[ ! -x "$WORK_DIR/ocamltest/ocamltest.opt" ]]; then
    cmd_setup
  fi
  export PATH="$PREFIX/bin:$(dirname "$(command -v zig)"):$PATH"
}

cmd_in_prefix() {
  if [[ ! -x "$TARGET_PREFIX/bin/ocamlc" ]]; then
    cmd_build
  fi
  ensure_setup in-prefix "$@"
  echo "==> Running test_in_prefix against $TARGET_PREFIX..."
  (
    cd "$WORK_DIR/testsuite/in_prefix"
    rm -rf ocamlrun* test-ocamlrun* poisoned-runtime test_* byt_* nat_* camllib ocamllib
    cp "$TARGET_PREFIX/bin/ocamlrun" test-ocamlrun
    mkdir -p poisoned-runtime
    ln -s ../../tools/poisonedruntime poisoned-runtime/ocamlrun
    export PATH="$WORK_DIR/testsuite/in_prefix/poisoned-runtime:$PATH"
    unset CAML_LD_LIBRARY_PATH OCAMLLIB CAMLLIB OCAMLPARAM OCAMLRUNPARAM CAMLRUNPARAM

    local nat_flag="--without-ocamlnat"
    [[ -x "$TARGET_PREFIX/bin/ocamlnat" ]] && nat_flag="--with-ocamlnat"

    ../tools/test_in_prefix.opt \
      --bindir "$TARGET_PREFIX/bin" \
      --libdir "../lib/ocaml" \
      "$nat_flag" \
      --with-ocamlopt \
      --with-runtime-search=enable \
      dynlink runtime_events str systhreads unix \
      --pwd "$WORK_DIR/testsuite/in_prefix" "$@"

    rm -rf poisoned-runtime test-ocamlrun*
  )
}

cmd_parallel() {
  ensure_setup parallel "$@"
  local jobs="${1:-$(nproc)}"
  echo "==> Running full OCaml testsuite ($TARGET) across $jobs parallel workers..."
  (
    cd "$WORK_DIR/testsuite"
    rm -f _log _log.* failure.stamp
    mkdir -p _logs
    rm -f _logs/*

    # Schedule largest test directories first so long-running suites start immediately
    for d in tests/*; do
      [[ -d "$d" ]] || continue
      printf "%04d %s\n" "$(find "$d" -type f | wc -l)" "$d"
    done | sort -rn | awk '{print $2}' | \
      xargs -P "$jobs" -I{} bash -c '
        dir="$1"
        name="${dir#tests/}"
        make --no-print-directory exec-one DIR="$dir" > "_logs/$name.log" 2>&1
      ' _ {}

    cat _logs/*.log | tee _log
    rm -rf _logs
    make --no-print-directory check-failstamp
    make --no-print-directory report
  )
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  build)
    cmd_build "$@"
    ;;
  setup)
    cmd_setup "$@"
    ;;
  in-prefix)
    cmd_in_prefix "$@"
    ;;
  one)
    ensure_setup one "$@"
    make -C "$WORK_DIR/testsuite" one "$@"
    ;;
  all)
    ensure_setup all "$@"
    make -C "$WORK_DIR/testsuite" all "$@"
    ;;
  parallel)
    cmd_parallel "$@"
    ;;
  clean)
    rm -rf "$STATE_DIR"
    ;;
  *)
    usage
    ;;
esac
