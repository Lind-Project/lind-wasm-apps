#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bash WASM build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Reuse host configure state when the inputs are unchanged.
#   2. Build only the native generator tools and generated files that the
#      WASM phase actually consumes.
#   3. Delete host-built objects and archives that must be rebuilt for WASM.
#   4. Rebuild bash and its libraries with the wasm32-wasi toolchain.
#   5. Stage a raw .wasm by default, and reserve heavier post-processing for
#      explicit full-artifact builds.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_ROOT="$APPS_ROOT/bash"
TOOL_ENV="$APPS_ROOT/build/.toolchain.env"

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck source=/dev/null
  . "$TOOL_ENV"
fi

if [[ -z "${CLANG:-}" ]]; then
  echo "[bash] ERROR: CLANG is not set. Run 'make preflight' from lind-wasm-apps root."
  exit 1
fi

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/build/sysroot}"
MERGED_SYSROOT="$APPS_ROOT/build/sysroot_merged"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
ADD_EXPORT_TOOL="${ADD_EXPORT_TOOL:-$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
##################
# These knobs are the script-level control surface for the speedups below.
# ``ARTIFACT_MODE=fast` gives a quick development path,while FORCE_CLEAN`
# and `FORCE_CONFIGURE` preserve a simple way to fall back to a from-scratch
# rebuild when debugging or validating the cache logic.
##################
ARTIFACT_MODE="${ARTIFACT_MODE:-full}"
FORCE_CLEAN="${FORCE_CLEAN:-0}"
FORCE_CONFIGURE="${FORCE_CONFIGURE:-0}"
##################
# LIND_DYLINK controls whether we produce a statically-linked or a shared
# (PIE/dynamic) wasm binary.  Set LIND_DYLINK=1 to get the shared path;
# the default is static (0).  The shared path adds the PIE linker flags, links
# in lind_debug.o, runs add-export-tool to inject the
# __wasm_apply_* and __stack_pointer exports, and uses the additional wasm-opt
# passes required for shared modules.
##################
LIND_DYLINK="${LIND_DYLINK:-0}"

# Output location
BASH_OUT_DIR="$APPS_ROOT/build/bash/bin"
BASH_STATE_DIR="$APPS_ROOT/build/.bash_state"
HOST_SIG_FILE="$BASH_STATE_DIR/host-config.sig"
CACHE_REVISION="2"
##################
# The state directory exists to remember whether the expensive host configure
# phase is still valid. That phase is slow, and in practice it only needs to
# rerun when bash's configure inputs change or the user explicitly asks for it.
##################
mkdir -p "$BASH_OUT_DIR" "$BASH_STATE_DIR"

WASM_COMPAT_H="$BASH_ROOT/wasm_compat.h"

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[bash] ERROR: merged sysroot '$MERGED_SYSROOT' not found."
  echo "        Run 'make merge-sysroot' (or 'make all') in lind-wasm-apps first."
  exit 1
fi

if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[bash] ERROR: base sysroot headers missing at '$BASE_SYSROOT'."
  echo "        Did you run 'make sysroot' in lind-wasm?"
  exit 1
fi

if [[ ! -f "$WASM_COMPAT_H" ]]; then
  echo "[bash] ERROR: missing bash/wasm_compat.h (it should be committed in the repo)."
  exit 1
fi

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

# Using arrays for flags to handle dynamic additions cleanly
CFLAGS_WASM=(
  -O2 -g -std=gnu89 -pthread
  -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1
  -include "$WASM_COMPAT_H"
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

# EH-based setjmp/longjmp (default). The legacy asyncify-based path is
# selected by setting LIND_ASYNCIFY_SETJMP=1, matching lind_compile behaviour.
if [[ -z "${LIND_ASYNCIFY_SETJMP:-}" ]]; then
  CFLAGS_WASM+=(-fwasm-exceptions -mllvm -wasm-enable-sjlj)
fi

# ----------------------------------------------------------------------
# Branch Logic: Dynamic vs Static Settings
# ----------------------------------------------------------------------
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[bash] Mode: DYNAMIC LINKING (LIND_DYLINK=1)"
  CFLAGS_WASM+=(-fPIC)

  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[bash] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'." >&2
    exit 1
  fi

  # lind_debug.o lives in the glibc build tree (not installed to the sysroot)
  DYLINK_CRT_OBJS=(
    "$LIND_WASM_ROOT/src/glibc/build/lind_debug.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[bash] ERROR: required dylink CRT object '$obj' not found." >&2
      exit 1
    fi
  done

  LDFLAGS_WASM=(
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
    "-Wl,--export=__stack_pointer"
    "-Wl,--export=__stack_low"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
    "${DYLINK_CRT_OBJS[@]}"
  )
else
  echo "[bash] Mode: STATIC LINKING (LIND_DYLINK=0 or unset)"

  LDFLAGS_WASM=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864"
    "-Wl,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )
fi

echo "[bash] using CLANG       = $CLANG"
echo "[bash] using AR          = $AR"
echo "[bash] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[bash] merged sysroot    = $MERGED_SYSROOT"
echo "[bash] output dir        = $BASH_OUT_DIR"
echo "[bash] LIND_DYLINK       = $LIND_DYLINK"
echo "[bash] artifact mode     = $ARTIFACT_MODE"
echo

##################
# These helpers make the incremental logic readable. `hash_file` turns a set
# of inputs into a stable digest, and `write_if_changed` avoids timestamp churn
# when generated compatibility files already contain the right content.
##################
hash_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    sha256sum "$path" | awk '{print $1}'
  else
    echo "missing"
  fi
}

write_if_changed() {
  local dest="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  return 0
}

##################
# Bash still needs a native configure pass because it generates host-side tools
# and headers such as `mkbuiltins`, `signames.h`, and parser outputs. The
# optimization is not "skip configure forever", but "rerun it only when the
# configure-relevant inputs actually changed."
##################
host_signature() {
  local configure_args
  configure_args=$(
    cat <<'EOF'
--without-bash-malloc
--disable-nls
--disable-profiling
--disable-job-control
EOF
  )
  cat <<EOF | sha256sum | awk '{print $1}'
rev=$CACHE_REVISION
configure=$(hash_file "$BASH_ROOT/configure")
makefile_in=$(hash_file "$BASH_ROOT/Makefile.in")
builtins_makefile_in=$(hash_file "$BASH_ROOT/builtins/Makefile.in")
parse_y=$(hash_file "$BASH_ROOT/parse.y")
pathnames_in=$(hash_file "$BASH_ROOT/pathnames.h.in")
patchlevel=$(hash_file "$BASH_ROOT/patchlevel.h")
args=$configure_args
EOF
}

##################
# Upstream bash can inject `-ldl` into the generated builtins makefile. That
# is sensible on a native Linux build, but it is not a valid dependency for
# the WASI link we do later, so we normalize that generated file here.
##################
ensure_ldl_patch() {
  if [[ -f "$BASH_ROOT/builtins/Makefile" ]] && grep -q -- '-ldl' "$BASH_ROOT/builtins/Makefile" 2>/dev/null; then
    echo "[bash] [patch] stripping -ldl from builtins/Makefile for WASI/native build"
    python3 - <<'PY' "$BASH_ROOT/builtins/Makefile"
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s2 = s.replace("-ldl", "")
if s2 != s:
    p.write_text(s2)
PY
  fi
}

pushd "$BASH_ROOT" >/dev/null

##################
# This is the main cache decision. The old script always did `distclean` and
# `configure`, which is correct but wasteful. Here we only refresh that host
# configuration state when the signature changed, when outputs are missing, or
# when the caller explicitly forces a rebuild.
##################
current_host_sig="$(host_signature)"
need_host_configure=0

if [[ "$FORCE_CLEAN" == "1" ]]; then
  need_host_configure=1
fi
if [[ "$FORCE_CONFIGURE" == "1" ]]; then
  need_host_configure=1
fi
if [[ ! -f "$HOST_SIG_FILE" ]] || [[ "$(cat "$HOST_SIG_FILE" 2>/dev/null || true)" != "$current_host_sig" ]]; then
  need_host_configure=1
fi
if [[ ! -f config.status ]] || [[ ! -f builtins/Makefile ]]; then
  need_host_configure=1
fi

if (( need_host_configure )); then
  echo "[bash] [host] refreshing configure state..."
  make distclean >/dev/null 2>&1 || true
  ./configure \
    --without-bash-malloc \
    --disable-nls \
    --disable-profiling \
    --disable-job-control
  ensure_ldl_patch
  printf '%s\n' "$current_host_sig" >"$HOST_SIG_FILE"
else
  echo "[bash] [host] reusing existing configure state"
  ensure_ldl_patch
fi

##################
# The previous script built a full native bash binary just to obtain a small
# set of generator tools and generated headers. That extra work is not needed.
# One subtlety, though, is that `mkbuiltins` and `builtext.h` are managed by
# the `builtins/Makefile`, and asking the top-level make plus the subdir make
# to build them concurrently can race at high `-j`. We therefore keep the
# top-level generated headers parallel, but route the builtins generator path
# through a dedicated submake so the dependency graph stays coherent.
##################
echo "[bash] [host] building targeted native prerequisites..."
make -j"$JOBS" \
  signames.h \
  pathnames.h \
  version.h \
  y.tab.h \
  syntax.c
make -j1 -C builtins \
  mkbuiltins \
  builtext.h

if [[ ! -x builtins/mkbuiltins ]]; then
  echo "[bash] ERROR: host builtins/mkbuiltins was not produced."
  exit 1
fi

##################
# Once the native generator outputs exist, the host-built objects are actually
# the wrong architecture for the final link. We remove only the objects and
# archives that must be rebuilt for WASM and deliberately keep the generator
# tools that the sub-builds still depend on.
##################
echo "[bash] [wasm] cleaning host-built core objects..."
rm -f \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  signames.o

echo "[bash] [wasm] cleaning host-built library objects (preserving mkbuiltins.o)..."
find builtins -maxdepth 1 -type f -name '*.o' ! -name 'mkbuiltins.o' -delete || true
rm -f lib/glob/*.o lib/sh/*.o lib/readline/*.o lib/tilde/*.o || true

echo "[bash] [wasm] cleaning host-built archives..."
rm -f \
  builtins/libbuiltins.a \
  lib/glob/libglob.a \
  lib/sh/libsh.a \
  lib/readline/libreadline.a \
  lib/readline/libhistory.a \
  lib/tilde/libtilde.a

##################
# The old script forced these rebuilds through `-j1`, which serialized work
# even though bash's makefiles already encode the relevant dependencies. Using
# `-j\"$JOBS\"` lets the existing build graph use the available cores.
##################
echo "[bash] [wasm] building core objects with wasm32-wasi toolchain..."
make -j"$JOBS" \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  LDFLAGS="${LDFLAGS_WASM[*]}" \
  AR="$AR" \
  ARFLAGS="crs" \
  RANLIB="echo" \
  TERMCAP_LIB="" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o

echo "[bash] [wasm] building builtins/libbuiltins.a..."
make -j"$JOBS" -C builtins \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libbuiltins.a

echo "[bash] [wasm] building lib/glob/libglob.a..."
make -j"$JOBS" -C lib/glob \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libglob.a

echo "[bash] [wasm] building lib/sh/libsh.a..."
make -j"$JOBS" -C lib/sh \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libsh.a

echo "[bash] [wasm] building lib/readline/libreadline.a + libhistory.a..."
make -j"$JOBS" -C lib/readline \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libreadline.a libhistory.a

##################
# Readline can archive its own `xmalloc.o`, but bash also links its own xmalloc
# implementation directly. Keeping both copies produces duplicate symbols, so
# we trim readline's copy and leave bash's version as the canonical one.
##################
for archive in libreadline.a libhistory.a; do
  if [[ -f "./lib/readline/$archive" ]]; then
    echo "[bash] [wasm] stripping xmalloc.o from ./lib/readline/$archive to avoid duplicate xmalloc/xrealloc."
    "$AR" d "./lib/readline/$archive" xmalloc.o || true
  fi
done

echo "[bash] [wasm] building lib/tilde/libtilde.a..."
make -j"$JOBS" -C lib/tilde \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libtilde.a

##################
# These compatibility stubs are generated in-tree because bash/readline expect
# a few Unix-y interfaces that are missing or intentionally simplified under
# WASI. `write_if_changed` keeps them deterministic without causing needless
# rebuilds on every invocation.
##################
TPUTS_STUB_C="$BASH_ROOT/tputs_stub.c"
TPUTS_STUB_O="$BASH_ROOT/tputs_stub.o"
write_if_changed "$TPUTS_STUB_C" <<'EOF'
/* Minimal termcap stubs for readline on WASI. */

int tputs(const char *str, int affcnt, int (*putc_fn)(int))
{
    (void)affcnt;
    if (!str || !putc_fn)
        return 0;
    const unsigned char *p = (const unsigned char *)str;
    while (*p)
        putc_fn(*p++);
    return 0;
}

char *tgoto(const char *cm, int destcol, int destline)
{
    (void)cm;
    (void)destcol;
    (void)destline;
    static char buf[1];
    buf[0] = '\0';
    return buf;
}

int tgetnum(const char *id)
{
    (void)id;
    return -1;
}

int tgetent(char *bp, const char *name)
{
    (void)bp;
    (void)name;
    return 0;
}

char *tgetstr(const char *id, char **area)
{
    (void)id;
    (void)area;
    return (char *)0;
}

int tgetflag(const char *id)
{
    (void)id;
    return 0;
}
EOF
echo "[bash] [wasm] compiling termcap stubs..."
$CC_WASM "${CFLAGS_WASM[@]}" -c "$TPUTS_STUB_C" -o "$TPUTS_STUB_O"

LOCALE_STUB_C="$BASH_ROOT/locale_stub.c"
LOCALE_STUB_O="$BASH_ROOT/locale_stub.o"
write_if_changed "$LOCALE_STUB_C" <<'EOF'
/* Minimal locale stub for WASM. Avoids heavy locale logic. */

#include <stddef.h>

size_t __ctype_get_mb_cur_max(void)
{
    return 1;
}
EOF
echo "[bash] [wasm] compiling locale stubs..."
$CC_WASM "${CFLAGS_WASM[@]}" -c "$LOCALE_STUB_C" -o "$LOCALE_STUB_O"

GROUPS_STUB_C="$BASH_ROOT/getgroups_stub.c"
GROUPS_STUB_O="$BASH_ROOT/getgroups_stub.o"
write_if_changed "$GROUPS_STUB_C" <<'EOF'
/* Minimal getgroups(2) stub for WASI. */

#include <sys/types.h>

int getgroups(int size, gid_t list[])
{
    (void)size;
    (void)list;
    return 0;
}
EOF
echo "[bash] [wasm] compiling getgroups stub..."
$CC_WASM "${CFLAGS_WASM[@]}" -c "$GROUPS_STUB_C" -o "$GROUPS_STUB_O"

BASH_RAW_WASM="$SCRIPT_DIR/bash.raw.wasm"
BASH_WASM="$SCRIPT_DIR/bash.wasm"
BASH_CWASM="$SCRIPT_DIR/bash.cwasm"
rm -f "$BASH_RAW_WASM" "$BASH_WASM" "$BASH_CWASM" "$BASH_OUT_DIR/bash"

echo "[bash] [wasm] linking bash -> $BASH_RAW_WASM ..."
$CC_WASM \
  -L./builtins \
  -L./lib/readline \
  -L./lib/glob \
  -L./lib/tilde \
  -L./lib/sh \
  "${LDFLAGS_WASM[@]}" \
  -o "$BASH_RAW_WASM" \
  "$LOCALE_STUB_O" \
  "$GROUPS_STUB_O" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  "$TPUTS_STUB_O" \
  -lbuiltins -lglob -lsh -lreadline -lhistory -ltilde

if [[ ! -f "$BASH_RAW_WASM" ]]; then
  echo "[bash] ERROR: bash.raw.wasm was not produced."
  exit 1
fi

##################
# Lind expects the runtime module to include the epoch-injection transform, so
# `wasm-opt` is not just an optional beautification pass here; it is part of
# producing a runnable default artifact. We therefore keep the raw compiler
# output for debugging as `bash.raw.wasm`, but write the runnable module to the
# traditional `bash.wasm` path. Full mode still adds the extra alias and cwasm.
##################
if [[ ! -x "$WASM_OPT" ]]; then
  echo "[bash] ERROR: wasm-opt not found at '$WASM_OPT'; cannot produce runnable Lind artifact." >&2
  exit 1
fi

### Added `--fpcast-emu` flag to fix bash errors liked indirect function mismatch and others
echo "[bash] running wasm-opt to produce runnable bash.wasm..."
if [[ "$LIND_DYLINK" == "1" ]]; then
  # Shared modules require the import-table and import-globals passes so that
  # lind-dylink can patch relocations at load time.
  "$WASM_OPT" \
    --enable-bulk-memory --enable-threads \
    --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
    --asyncify --pass-arg=asyncify-import-globals \
    --fpcast-emu --pass-arg=relocatable-fpcast \
    --debuginfo -O2 \
    "$BASH_RAW_WASM" -o "$BASH_WASM"
else
  "$WASM_OPT" --epoch-injection --asyncify --fpcast-emu --debuginfo -O2 \
    "$BASH_RAW_WASM" -o "$BASH_WASM"
fi

# Add dylink exports after wasm-opt (must come after optimization to avoid
# exports being stripped or mangled by the optimization passes).
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[bash] [dylink] injecting wasm exports via add-export-tool..."
  "$ADD_EXPORT_TOOL" "$BASH_WASM" "$BASH_WASM" \
    __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
  "$ADD_EXPORT_TOOL" "$BASH_WASM" "$BASH_WASM" \
    __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$BASH_WASM" "$BASH_WASM" \
    __stack_pointer global __stack_pointer
fi

### If choosing the fast path, .cwasm is not generated
### Only .cwasm is copied to the build folder
### The build exits after this

if [[ "$ARTIFACT_MODE" == "fast" ]]; then
	echo "[bash] artifact mode is fast; keeping bash.wasm runnable and skipping only cwasm generation."
	echo "Only .cwasm binary is copied to build/bash folder and hence no binaries are copied"
	echo "Exiting..."
	exit 1
fi

if [[ -x "$LIND_BOOT" ]]; then
   echo "[bash] generating cwasm via lind-boot --precompile..."
   if "$LIND_BOOT" --precompile "$BASH_WASM"; then
      if [[ -f "$BASH_CWASM" ]]; then
        # Strip .cwasm extension for final staged binary (required by issue #125)
        cp "$BASH_CWASM" "$BASH_OUT_DIR/bash"
        echo "[bash] staged final binary: $BASH_OUT_DIR/bash"
        cp "$BASH_OUT_DIR/bash" "$BASH_OUT_DIR/sh"
        echo "[bash] created copy: $BASH_OUT_DIR/sh"
      else
        echo "[bash] ERROR: No .cwasm binary generated and hence no binaries copied to build/bash folder."
	echo "[bash] ERROR: Exiting.."
	exit 1
      fi
   else
      echo "[bash] ERROR: lind-boot --precompile failed; skipping cwasm generation."
      exit 1
   fi
else
   echo "[bash] ERROR: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
   exit 1
fi

popd >/dev/null

echo
echo "[bash] build complete. Outputs under:"
echo "  $BASH_OUT_DIR"
ls -lh "$BASH_OUT_DIR" || true
