#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# coreutils WASI build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Prepare a cross-compiling configure environment for WASI.
#   2. Apply a small set of source/configure patches needed for this target.
#   3. Reuse configure state when those inputs are unchanged.
#   4. Build and generate wasm outputs
#   5. Apply optimization and precompilation to generate .cwasm binaries and fail the build if .cwasm is not generated.
#   6. Stage .cwasm binaries
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COREUTILS_ROOT="$APPS_ROOT/coreutils"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
BUILD_ROOT="$APPS_BUILD/coreutils_wasi"
BUILD_DIR="$BUILD_ROOT/build"
STAGE_DIR="$APPS_BUILD/coreutils/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
##################
# These flags define the new runtime policy for the script. ARTIFACT_MODE=fast is a
# faster path that stops after raw `.wasm` outputs, while the default mode 'full' 
# enables explicit switches for from-scratch rebuilds and for the old richer artifact set
# and generates .cwasm binary
##################
LIND_DYLINK="${LIND_DYLINK:-0}"
ARTIFACT_MODE="${ARTIFACT_MODE:-full}"
FORCE_CLEAN="${FORCE_CLEAN:-0}"
FORCE_CONFIGURE="${FORCE_CONFIGURE:-0}"
CACHE_REVISION="2"
STATE_DIR="$BUILD_ROOT/.state"
CONFIG_SIG_FILE="$STATE_DIR/config.sig"
##################
# coreutils spends a lot of time in its configure and patch pipeline. The
# state directory stores a signature for that pipeline so repeated runs can
# skip it when the relevant inputs are unchanged.
##################
mkdir -p "$STATE_DIR"

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[coreutils] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$COREUTILS_ROOT" ]]; then
  echo "[coreutils] ERROR: coreutils source dir not found at: $COREUTILS_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[coreutils] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$STAGE_DIR"

WASM_COMPAT_H="$COREUTILS_ROOT/wasm_compat.h"
WASM_COMPAT_INC=()
if [[ -f "$WASM_COMPAT_H" ]]; then
  WASM_COMPAT_INC=(-include "$WASM_COMPAT_H")
else
  echo "[coreutils] NOTE: $WASM_COMPAT_H missing; continuing without -include."
fi

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1
  -DSLOW_BUT_NO_HACKS=1
  "${WASM_COMPAT_INC[@]}"
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[coreutils] Dynamic linking mode enabled (LIND_DYLINK=1)"
  CFLAGS_WASM+=(-fPIC)

  # add-export-tool is used after wasm-opt to export relocation and stack symbols
  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[coreutils] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'" >&2
    exit 1
  fi

  # Extra CRT objects required for dynamic PIE executables
  DYLINK_CRT_OBJS=(
    "$MERGED_SYSROOT/lib/wasm32-wasi/set_stack_pointer.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/crt1_shared.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/lind_utils.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[coreutils] ERROR: required dylink CRT object '$obj' not found." >&2
      echo "[coreutils] Hint: rebuild sysroot on the dylink branch (make sysroot in lind-wasm)." >&2
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
  # Configure-only LDFLAGS: use the static link flags so autoconf feature
  # detection correctly fails for missing symbols. The --allow-undefined +
  # --unresolved-symbols=import-dynamic flags in LDFLAGS_WASM make link tests
  # succeed for every function, producing false positives on platform-specific
  # functions (pstat_getdynamic, nanotime, getppriv, etc.).
  LDFLAGS_CONFIGURE=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )
else
  LDFLAGS_WASM=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )
  LDFLAGS_CONFIGURE=("${LDFLAGS_WASM[@]}")
fi

echo "[coreutils] using CLANG       = $CLANG"
echo "[coreutils] using AR          = $AR"
echo "[coreutils] using RANLIB      = $RANLIB"
echo "[coreutils] merged sysroot    = $MERGED_SYSROOT"
echo "[coreutils] build dir         = $BUILD_DIR"
echo "[coreutils] stage dir         = $STAGE_DIR"
echo "[coreutils] artifact mode     = $ARTIFACT_MODE"
echo "[coreutils] dylink mode       = $LIND_DYLINK"
echo

##################
# These helpers keep the incremental logic understandable. `hash_file` feeds
# the configure signature, `write_if_changed` avoids pointless timestamp
# updates, and the bounded background helpers let full-mode post-processing use
# parallelism without launching an unbounded number of jobs.
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

run_limited() {
  local limit="$1"
  shift
  while (( $(jobs -rp | wc -l) >= limit )); do
    wait -n || true
  done
  "$@" &
}

wait_for_background_jobs() {
  local rc=0
  while [[ -n "$(jobs -rp)" ]]; do
    if ! wait -n; then
      rc=1
    fi
  done
  return "$rc"
}

run_wasm_opt_replace() {
  local src="$1"
  local raw="$2"
  local out="$3"
  local tmp="${out}.tmp"
  cp "$src" "$raw"
  if [[ "$LIND_DYLINK" == "1" ]]; then
    if "$WASM_OPT" \
        --enable-bulk-memory --enable-threads \
        --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
        --asyncify --pass-arg=asyncify-import-globals \
        --debuginfo \
        "$raw" -o "$tmp"; then
      mv "$tmp" "$out"
    else
      rm -f "$tmp"
      return 1
    fi
  else
    if "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 "$raw" -o "$tmp"; then
      mv "$tmp" "$out"
    else
      rm -f "$tmp"
      return 1
    fi
  fi
}

publish_stage_dir() {
  local src_dir="$1"
  mkdir -p "$STAGE_DIR"
  find "$STAGE_DIR" -maxdepth 1 -type f \( -name '*.wasm' -o -name '*.raw.wasm' -o -name '*.opt.wasm' -o -name '*.cwasm' \) -delete
  cp -a "$src_dir"/. "$STAGE_DIR"/
}

##################
# We force static-only behavior here because shared-library assumptions are a
# poor match for this wasm build and tend to produce linker behavior we do not
# want. Setting these cache variables up front gives configure a consistent
# cross-compilation story.
##################
export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes
export ac_cv_prog_cc_pic_works=no
export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_CONFIGURE[*]}"

CONFIG_SITE_FILE="$BUILD_ROOT/config.site"
##################
# `config.site` is how we teach configure about the constraints of this target
# without modifying upstream build logic. Writing it with `write_if_changed`
# matters because a needless rewrite would make the signature look stale and
# force us back through configure for no technical reason.
##################
write_if_changed "$CONFIG_SITE_FILE" <<'EOF'
# coreutils on WASI: do not attempt to run test executables
cross_compiling=yes

# ---- coreutils/gnulib mountlist: disable entirely ----
fu_cv_mounted_fs_supported=no
gl_cv_list_mounted_fs=no
fu_cv_sys_mounted_fread=no
fu_cv_sys_mounted_getmntent=no
fu_cv_sys_mounted_getmntinfo=no
fu_cv_sys_mounted_getfsstat=no
fu_cv_sys_mounted_mnttab=no
fu_cv_sys_mounted_vfstab=no
fu_cv_sys_mounted_vmount=no

ac_cv_func_listmntent=no
ac_cv_func_openat=no
ac_cv_func_fstatat=no
ac_cv_func_unlinkat=no
ac_cv_func_fchmodat=no
ac_cv_func_mkdirat=no
ac_cv_func_fchownat=no
ac_cv_func_linkat=no
ac_cv_func_symlinkat=no
ac_cv_func_readlinkat=no
ac_cv_func_inotify_init=no
ac_cv_search_crypt=no
EOF
export CONFIG_SITE="$CONFIG_SITE_FILE"

##################
# This patch keeps coreutils from treating the lack of a traditional mount table
# as a fatal configure error. The key detail is that we rewrite the patched
# configure script only when its content actually changes, so the configure
# cache can remain stable across repeated invocations.
##################
patch_mountlist_fatal() {
  local in="$COREUTILS_ROOT/configure"
  local out="$BUILD_ROOT/configure.patched"
  python3 - <<'PY' "$in" "$out"
import pathlib, re, sys
inp = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
s = inp.read_text(errors="ignore")
needle = r'as_fn_error\s+\$\?\s+"could not determine how to read list of mounted file systems"\s+"\$LINENO"\s+5'
repl = r'''{ echo "configure: WARNING: disabling mountlist on WASI (no mount table support)" >&2; }
fu_cv_mounted_fs_supported=no
gl_cv_list_mounted_fs=no
fu_cv_sys_mounted_fread=no
fu_cv_sys_mounted_getmntent=no
fu_cv_sys_mounted_getmntinfo=no
fu_cv_sys_mounted_getfsstat=no
fu_cv_sys_mounted_mnttab=no
fu_cv_sys_mounted_vfstab=no
fu_cv_sys_mounted_vmount=no
'''
s2, _ = re.subn(needle, repl, s)
if out.exists() and out.read_text(errors="ignore") == s2:
    sys.exit(0)
out.write_text(s2)
out.chmod(0o755)
PY
}

##################
# Several gnulib files need small WASI-specific edits. We keep those edits in
# the script, but make them content-preserving so the source tree is only
# rewritten when the effective patch result changes.
##################
patch_file_if_needed() {
  local target="$1"
  local code="$2"
  python3 - <<'PY' "$target" "$code"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
code = sys.argv[2]
s = p.read_text(errors="ignore")
ns = {"re": re, "s": s}
exec(code, ns)
s2 = ns.get("s2", s)
if s2 != s:
    p.write_text(s2)
PY
}

##################
# The portability patches are intentionally narrow: they only address the
# gnulib cases that currently block the WASI build. That keeps the script
# understandable for students while still making repeat builds cheaper by
# avoiding unconditional rewrites of the same files.
##################
patch_portability_sources() {
  local f
  for f in "$COREUTILS_ROOT/lib/freadahead.c" "$COREUTILS_ROOT/lib/freadptr.c" "$COREUTILS_ROOT/lib/freadseek.c"; do
    [[ -f "$f" ]] || continue
    patch_file_if_needed "$f" $'s2 = re.sub(\n  r\'(#elif\\s+defined\\s+SLOW_BUT_NO_HACKS\\s*/\\*[^*]*\\*/\\s*\\n)(.*?\\n)(#else\\s*\\n\\s*#error\\s+\\"Please port gnulib .*?\\n\\s*#endif)\',\n  lambda m: m.group(1) + "  /* WASI fallback: no stdio internals; behave conservatively. */\\n  return 0;\\n" + m.group(3),\n  s,\n  flags=re.S\n)\ns2 = re.sub(\n  r\'(#elif\\s+defined\\s+SLOW_BUT_NO_HACKS\\s*\\n)(.*?\\n)(#else\\s*\\n\\s*#error\\s+\\"Please port gnulib .*?\\n\\s*#endif)\',\n  lambda m: m.group(1) + "  /* WASI fallback: no stdio internals; behave conservatively. */\\n  return 0;\\n" + m.group(3),\n  s2,\n  flags=re.S\n)'
  done

  local fseterr="$COREUTILS_ROOT/lib/fseterr.c"
  if [[ -f "$fseterr" ]]; then
    patch_file_if_needed "$fseterr" $'pat = r\'(#elif\\s+defined\\s+__MINT__[^#]*\\n\\s*fp->__error\\s*=\\s*1;\\s*\\n)(#elif\\s+0\\s*/\\*\\s*unknown\\s*\\*/|#else\\s*\\n\\s*#error)\'\nm = re.search(pat, s, flags=re.S)\ns2 = s\nif m and "#elif defined __wasi__" not in s:\n  insert = m.group(1) + "#elif defined __wasi__\\n  (void)fp; /* WASI: no FILE internals; best-effort no-op. */\\n"\n  s2 = s[:m.start(1)] + insert + s[m.end(1):]'
  fi

  local fseeko="$COREUTILS_ROOT/lib/fseeko.c"
  if [[ -f "$fseeko" ]]; then
    patch_file_if_needed "$fseeko" $'pat = r\'(?ms)^#else\\s*\\n\\s*#error\\s+\\"Please port gnulib fseeko\\.c.*?\\"\\s*\\n#endif\'\nrepl = "#else\\n  /* WASI fallback: no stdio internals; just call the underlying fseeko/fseek. */\\n  return fseeko (fp, offset, whence);\\n#endif"\ns2 = re.sub(pat, repl, s, count=1)'
  fi

  local unlinkat="$COREUTILS_ROOT/lib/unlinkat.c"
  if [[ -f "$unlinkat" ]]; then
    patch_file_if_needed "$unlinkat" $'s2 = s\nif "<stdlib.h>" not in s:\n  s2 = re.sub(r\'(#include\\s+<unistd\\.h>\\s*\\n)\', r\'\\1#include <stdlib.h>\\n\', s, count=1)\n  if s2 == s:\n    s2 = re.sub(r\'(#include\\s+<config\\.h>\\s*\\n)\', r\'\\1#include <stdlib.h>\\n\', s, count=1)'
  fi

  local sigaction_c="$COREUTILS_ROOT/lib/sigaction.c"
  if [[ -f "$sigaction_c" ]]; then
    write_if_changed "$sigaction_c" <<'EOF'
/* WASI stub for gnulib sigaction module. */
#include <config.h>
#include <signal.h>
#include <errno.h>

int sigaction (int sig, const struct sigaction *restrict act,
               struct sigaction *restrict oact)
{
  (void)sig;
  (void)act;
  (void)oact;
  errno = ENOTSUP;
  return -1;
}
EOF
  fi
}

patch_generated_signal_h_after_configure() {
  local gen="$BUILD_DIR/lib/signal.h"
  [[ -f "$gen" ]] || return 0
  python3 - <<'PY' "$gen"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")
m = re.search(r'\nstruct sigaction\s*\{.*?\n\};\n', s, flags=re.S)
if not m:
    sys.exit(0)
block = m.group(0)
wrapped = "\n#ifndef __wasi__\n" + block + "#endif\n"
s2 = s[:m.start()] + wrapped + s[m.end():]
if s2 != s:
    p.write_text(s2)
PY
}

patch_mountlist_fatal
patch_portability_sources

HOST_TRIPLET="${HOST_TRIPLET:-wasm32-unknown-linux-gnu}"
BUILD_TRIPLET="${BUILD_TRIPLET:-$(./config.guess 2>/dev/null || echo x86_64-unknown-linux-gnu)}"

##################
# The configure signature is the teaching point for the optimization: if the
# config.site content, patched sources, toolchain, and key flags are all the
# same, then rerunning configure is busywork rather than useful computation.
##################
config_signature() {
  cat <<EOF | sha256sum | awk '{print $1}'
rev=$CACHE_REVISION
config_site=$(hash_file "$CONFIG_SITE_FILE")
configure_patched=$(hash_file "$BUILD_ROOT/configure.patched")
configure=$(hash_file "$COREUTILS_ROOT/configure")
freadahead=$(hash_file "$COREUTILS_ROOT/lib/freadahead.c")
freadptr=$(hash_file "$COREUTILS_ROOT/lib/freadptr.c")
freadseek=$(hash_file "$COREUTILS_ROOT/lib/freadseek.c")
fseterr=$(hash_file "$COREUTILS_ROOT/lib/fseterr.c")
fseeko=$(hash_file "$COREUTILS_ROOT/lib/fseeko.c")
unlinkat=$(hash_file "$COREUTILS_ROOT/lib/unlinkat.c")
sigaction=$(hash_file "$COREUTILS_ROOT/lib/sigaction.c")
clang=$CLANG
ar=$AR
ranlib=$RANLIB
host=$HOST_TRIPLET
build=$BUILD_TRIPLET
cflags=${CFLAGS_WASM[*]}
ldflags=${LDFLAGS_WASM[*]}
dylink=$LIND_DYLINK
EOF
}

##################
# This is the central reuse decision. Instead of always deleting configure
# outputs and starting over, we only rerun configure when the signature says
# the inputs changed, when the user forces it, or when the generated Makefile
# is missing.
##################
current_config_sig="$(config_signature)"
need_configure=0
if [[ "$FORCE_CLEAN" == "1" || "$FORCE_CONFIGURE" == "1" ]]; then
  need_configure=1
fi
if [[ ! -f "$CONFIG_SIG_FILE" ]] || [[ "$(cat "$CONFIG_SIG_FILE" 2>/dev/null || true)" != "$current_config_sig" ]]; then
  need_configure=1
fi
if [[ ! -f "$BUILD_DIR/Makefile" ]]; then
  need_configure=1
fi

if (( need_configure )); then
  echo "[coreutils] configuring (best-effort; may still warn)"
  (
    cd "$BUILD_DIR"
    rm -f config.cache || true
    "$BUILD_ROOT/configure.patched" \
      --srcdir="$COREUTILS_ROOT" \
      --build="$BUILD_TRIPLET" \
      --host="$HOST_TRIPLET" \
      --disable-shared \
      --enable-static \
      --disable-libtool-lock \
      --without-selinux \
      --without-libcap \
      CC="$CC_WASM" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      CFLAGS="${CFLAGS_WASM[*]}" \
      CPPFLAGS="$CPPFLAGS" \
      LDFLAGS="${LDFLAGS_CONFIGURE[*]}" \
      || echo "[coreutils] WARNING: configure exited nonzero ($?)."
  )
  patch_generated_signal_h_after_configure
  printf '%s\n' "$current_config_sig" >"$CONFIG_SIG_FILE"
else
  echo "[coreutils] reusing existing configure state"
fi

if [[ ! -f "$BUILD_DIR/Makefile" ]]; then
  echo "[coreutils] ERROR: configure failed before producing Makefile." >&2
  if [[ -f "$BUILD_DIR/config.log" ]]; then
    grep -n -m1 -E 'Exec format error|configure: error:|: error:|cannot execute binary file' "$BUILD_DIR/config.log" >&2 || true
  fi
  exit 1
fi

##################
# The actual build still goes through coreutils' own makefiles unchanged. The
# goal here is not to outsmart them, only to avoid paying the setup cost on
# every run and to preserve the existing best-effort staging behavior.
##################
echo "[coreutils] building (best-effort; partial failures allowed)"
(
  cd "$BUILD_DIR"
  set +e
  make -j"$JOBS" V=1 \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}" \
    all
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "[coreutils] NOTE: make returned $rc (expected for some tools); staging whatever built."
  fi
)

echo "[coreutils] staging wasm binaries..."
SRC_BIN_DIR="$BUILD_DIR/src"
if [[ ! -d "$SRC_BIN_DIR" ]]; then
  echo "[coreutils] ERROR: expected build output dir '$SRC_BIN_DIR' not found" >&2
  exit 1
fi


# Keep intermediates in a dedicated folder instead of a temp directory
TMP_STAGE_DIR="$BUILD_ROOT/intermediates"
mkdir -p "$TMP_STAGE_DIR"


###############################################################################
# INTERMEDIATE STAGING & WASM VALIDATION
#
# This section safely extracts the compiled WebAssembly binaries from the raw 
# build directory and moves them to a persistent 'intermediates' folder.
#
# We use an embedded Python script here because validating binary files in pure 
# Bash is slow and error-prone. The Python script performs the following:
#
#   1. Scans the compiler output directory ($SRC_BIN_DIR).
#   2. Ignores standard C/C++ build artifacts (like .o, .a, .la files).
#   3. Performs a "Magic Number" validation: It reads the first 4 bytes of 
#      each file to ensure it perfectly matches the WebAssembly header (\0asm).
#   4. Copies only the verified binaries to the intermediates directory 
#      ($TMP_STAGE_DIR) and appends a '.wasm' extension to the filename.
#   5. Returns the total count of staged files to bash ($staged_count) so we 
#      can abort if the build produced nothing usable.
###############################################################################

staged_count="$(
python3 - <<'PY' "$SRC_BIN_DIR" "$TMP_STAGE_DIR"
import os, sys
src = sys.argv[1]
dst = sys.argv[2]
os.makedirs(dst, exist_ok=True)
count = 0
for name in sorted(os.listdir(src)):
    p = os.path.join(src, name)
    if not os.path.isfile(p) or name.endswith((".o", ".a", ".la", ".lo", ".Plo")):
        continue
    try:
        with open(p, "rb") as f:
            if f.read(4) != b"\0asm":
                continue
    except Exception:
        continue
    out = os.path.join(dst, name + ".wasm")
    with open(p, "rb") as fi, open(out, "wb") as fo:
        fo.write(fi.read())
    count += 1
print(count)
PY
)"

if [[ "$staged_count" == "0" ]]; then
  echo "[coreutils] ERROR: staging found no wasm binaries in '$SRC_BIN_DIR'; leaving existing staged outputs untouched." >&2
  exit 1
fi

echo "[coreutils] staged $staged_count wasm binaries into temporary dir $TMP_STAGE_DIR"

shopt -s nullglob
wasm_files=("$TMP_STAGE_DIR"/*.wasm)
shopt -u nullglob
if (( ${#wasm_files[@]} == 0 )); then
  echo "[coreutils] ERROR: temporary staging dir contains no .wasm files; leaving existing staged outputs untouched." >&2
  exit 1
fi

if [[ ! -x "$WASM_OPT" ]]; then
  echo "[coreutils] ERROR: wasm-opt not found at '$WASM_OPT'; cannot produce runnable Lind artifacts."
  exit 1
fi

# Convert .wasm directly to .opt.wasm
# We can safely parallelize the expensive per-binary post-process steps because
# each output file is independent. The worker limiter keeps that concurrency
# tied to `JOBS` instead of spawning one process per staged binary.
##################
echo "[coreutils] Step 1: Converting .wasm to .opt.wasm..."
for w in "${wasm_files[@]}"; do
  opt_file="${w%.wasm}.opt.wasm"
  if [[ "$LIND_DYLINK" == "1" ]]; then
    run_limited "$JOBS" "$WASM_OPT" \
      --enable-bulk-memory --enable-threads \
      --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
      --asyncify --pass-arg=asyncify-import-globals \
      --debuginfo \
      "$w" -o "$opt_file"
  else
    run_limited "$JOBS" "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 "$w" -o "$opt_file"
  fi
done
wait_for_background_jobs

# Verify .opt.wasm generation
shopt -s nullglob
opt_files=("$TMP_STAGE_DIR"/*.opt.wasm)
shopt -u nullglob

if (( ${#opt_files[@]} == 0 || ${#opt_files[@]} != ${#wasm_files[@]} )); then
  echo "[coreutils] ERROR: Failed to generate all .opt.wasm files." >&2
  exit 1
fi

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[coreutils] adding dylink exports via add-export-tool..."
  for w in "${opt_files[@]}"; do
    "$ADD_EXPORT_TOOL" "$w" "$w" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
    "$ADD_EXPORT_TOOL" "$w" "$w" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
    "$ADD_EXPORT_TOOL" "$w" "$w" __stack_pointer global __stack_pointer
  done
fi

if [[ "$ARTIFACT_MODE" != "full" ]]; then
  echo "[coreutils] artifact mode is fast; Skipping cwasm generation."
  echo "[coreutils] ERROR: No binaries copied to build/coreutils folder"
  exit 1
fi

if [[ ! -x "$LIND_BOOT" ]]; then
  echo "[coreutils] ERROR: lind-boot not found at '$LIND_BOOT'." >&2
  exit 1
fi

# Convert .opt.wasm to .cwasm
echo "[coreutils] Step 2: Converting .opt.wasm to .cwasm..."
for opt in "${opt_files[@]}"; do
  run_limited "$JOBS" "$LIND_BOOT" --precompile "$opt"
done
wait_for_background_jobs

# Verify .cwasm generation (lind-boot appends .cwasm to the input file)
shopt -s nullglob
cwasm_files=("$TMP_STAGE_DIR"/*.opt.cwasm)
shopt -u nullglob

if (( ${#cwasm_files[@]} == 0 || ${#cwasm_files[@]} != ${#opt_files[@]} )); then
  echo "[coreutils] ERROR: Failed to generate all .cwasm files." >&2
  exit 1
fi

# 5. Stage only the final binaries
echo "[coreutils] Staging final binaries to $STAGE_DIR..."
for cw in "${cwasm_files[@]}"; do
  # Strip out the folder path and the .opt.cwasm extensions (e.g., "ls.opt.cwasm" -> "ls")
  binary_name="$(basename "${cw%.opt.cwasm}")"

  # Copy ONLY the final, extensionless binary to your final bin/ folder
  cp "$cw" "$STAGE_DIR/$binary_name"
done

echo
echo "[coreutils] Build successfully completed! Outputs under:"
echo "  $STAGE_DIR"

ls -lh "$STAGE_DIR" || true
