#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# grep WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU grep 3.12 to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
#
# Supports both Static (default) and Dynamic (LIND_DYLINK=1) builds.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GREP_ROOT="$APPS_ROOT/grep"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/grep/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
LIND_DYLINK="${LIND_DYLINK:-0}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[grep] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# Sanity
if [[ ! -d "$GREP_ROOT" ]]; then
  echo "[grep] ERROR: grep source dir not found at: $GREP_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[grep] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) Base WASM Toolchain Flags
# ----------------------------------------------------------------------
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

# ----------------------------------------------------------------------
# 3) Branch Logic: Dynamic vs Static Settings
# ----------------------------------------------------------------------
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[grep] Mode: DYNAMIC LINKING (LIND_DYLINK=1)"
  CFLAGS_WASM+=(-fPIC)

  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[grep] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'" >&2
    exit 1
  fi

  DYLINK_CRT_OBJS=(
    "$MERGED_SYSROOT/lib/wasm32-wasi/set_stack_pointer.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/crt1_shared.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/lind_utils.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[grep] ERROR: required dylink CRT object '$obj' not found." >&2
      exit 1
    fi
  done

  LDFLAGS_WASM=(
    "-nostartfiles"
    "-Wl,-pie"
    "-Wl,--import-table"
    "-Wl,--import-memory"
    "-Wl,--export-memory"
    "-Wl,--shared-memory"
    "-Wl,--max-memory=67108864"
    "-Wl,--allow-undefined"
    "-Wl,--unresolved-symbols=import-dynamic"
    "-Wl,--export=__wasm_call_ctors"
    "-Wl,--export-if-defined=__wasm_init_tls"
    "-Wl,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
    "${DYLINK_CRT_OBJS[@]}"
  )
  
  LDFLAGS_CONFIGURE=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )

  export enable_shared=no
  export enable_static=yes
  export lt_cv_prog_compiler_pic_works=yes
  export lt_cv_prog_compiler_static_works=yes
else
  echo "[grep] Mode: STATIC LINKING (LIND_DYLINK=0 or unset)"
  
  LDFLAGS_WASM=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )
  LDFLAGS_CONFIGURE=("${LDFLAGS_WASM[@]}")

  export enable_shared=no
  export enable_static=yes
  export lt_cv_prog_compiler_pic_works=no
  export lt_cv_prog_compiler_static_works=yes
fi

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_CONFIGURE[*]}"

echo "[grep] using CLANG       = $CLANG"
echo "[grep] using AR          = $AR"
echo "[grep] using RANLIB      = $RANLIB"
echo "[grep] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[grep] merged sysroot    = $MERGED_SYSROOT"
echo "[grep] stage dir         = $STAGE_DIR"
echo "[grep] CC_WASM           = $CC_WASM"
echo

# ----------------------------------------------------------------------
# 4) Patch gnulib fpending.c — add __wasi__ fallback before #error
# ----------------------------------------------------------------------
patch_fpending() {
  local f="$GREP_ROOT/lib/fpending.c"
  [[ -f "$f" ]] || return 0
  if grep -q '__wasi__' "$f"; then
    echo "[grep] [patch] fpending.c already patched; skipping."
    return 0
  fi
  python3 - <<'PY' "$f"
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

old = """#else
# error "Please port gnulib fpending.c to your platform!"
  return 1;
#endif"""

new = """#elif defined __wasi__
  /* WASI/Lind fallback: no stdio internals; return 0 (no pending bytes). */
  return 0;
#else
# error "Please port gnulib fpending.c to your platform!"
  return 1;
#endif"""

if old in s:
    p.write_text(s.replace(old, new))
    print(f"[grep] [patch] added __wasi__ fallback to {p}")
else:
    print(f"[grep] WARN: fpending.c patch pattern not found in {p}", file=sys.stderr)
PY
}

patch_fpending

# ----------------------------------------------------------------------
# 5) Prevent autotools regeneration (no aclocal/automake/autoconf needed)
#    Touch generated files in dependency order so make won't re-run them.
# ----------------------------------------------------------------------
(
  cd "$GREP_ROOT"
  # Autoconf/automake chain: configure.ac → aclocal.m4 → configure → Makefile.in
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  # Texinfo/man: *.texi → *.info, prevent makeinfo invocation
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' -o -name '*.in.1' 2>/dev/null | xargs -r touch
)

# ----------------------------------------------------------------------
# 6) Configure
# ----------------------------------------------------------------------
BUILD_TRIPLET="$("$GREP_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[grep] configuring…"
(
  cd "$GREP_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_CONFIGURE[*]}"
)

if [[ ! -f "$GREP_ROOT/Makefile" ]]; then
  echo "[grep] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 7) Build
# ----------------------------------------------------------------------
echo "[grep] building…"

# Inject the true Wasm LDFLAGS and CFLAGS for the make step
make -C "$GREP_ROOT" -j"$JOBS" V=1 \
  CFLAGS="${CFLAGS_WASM[*]}" \
  LDFLAGS="${LDFLAGS_WASM[*]}"

# ----------------------------------------------------------------------
# 8) Stage binary
# ----------------------------------------------------------------------
GREP_BIN="$GREP_ROOT/src/grep"
if [[ ! -f "$GREP_BIN" ]]; then
  echo "[grep] ERROR: expected binary '$GREP_BIN' not found after build." >&2
  exit 1
fi

GREP_WASM="$SCRIPT_DIR/grep.wasm"
GREP_OPT_WASM="$SCRIPT_DIR/grep.opt.wasm"
cp "$GREP_BIN" "$GREP_WASM"

# ----------------------------------------------------------------------
# 9) wasm-opt & exports
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[grep] running wasm-opt (asyncify + optimization)…"
  if [[ "$LIND_DYLINK" == "1" ]]; then
    "$WASM_OPT" \
      --enable-bulk-memory --enable-threads \
      --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
      --asyncify --pass-arg=asyncify-import-globals \
      -O2 --debuginfo \
      "$GREP_WASM" -o "$GREP_OPT_WASM"
  else
    "$WASM_OPT" \
      --epoch-injection \
      --asyncify \
      -O2 --debuginfo \
      "$GREP_WASM" -o "$GREP_OPT_WASM"
  fi
else
  echo "[grep] ERROR: wasm-opt not found at '$WASM_OPT'; skipping optimization. Exiting.."
  exit 1
fi

if [[ ! -f "$GREP_OPT_WASM" ]]; then
  echo "[grep] ERROR: Failed to generate $GREP_OPT_WASM; Exiting.."
  exit 1
fi

# Add dylink exports if dynamic linking is enabled
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[grep] adding dylink exports via add-export-tool..."
  "$ADD_EXPORT_TOOL" "$GREP_OPT_WASM" "$GREP_OPT_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
  "$ADD_EXPORT_TOOL" "$GREP_OPT_WASM" "$GREP_OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$GREP_OPT_WASM" "$GREP_OPT_WASM" __stack_pointer global __stack_pointer
fi

# ----------------------------------------------------------------------
# 10) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[grep] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$GREP_OPT_WASM"; then
    
    GREP_OPT_CWASM="$SCRIPT_DIR/grep.opt.cwasm"

    if [[ -f "$GREP_OPT_CWASM" ]]; then
      cp "$GREP_OPT_CWASM" "$STAGE_DIR/grep"
      echo "[grep] grep staged as $STAGE_DIR/grep"
    else
      echo "[grep] ERROR: No .cwasm binaries generated and no binaries copied to the build folder. Exiting.."
      exit 1
    fi
  else
    echo "[grep] ERROR: lind-boot --precompile failed; skipping cwasm generation."
    echo "[grep] ERROR: No binaries copied to the build folder. Exiting.."
    exit 1
  fi
else
  echo "[grep] ERROR: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
  echo "[grep] ERROR: No binaries copied to the build folder. Exiting.."
  exit 1
fi

echo
echo "[grep] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true


