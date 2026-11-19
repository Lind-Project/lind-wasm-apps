#!/usr/bin/env bash
# Shared grate support for <app>/run_tests.sh (see TESTING.md, "Running under a grate").
#
# Source this after test_lib.sh, once SCRIPT_DIR and LINDFS_ROOT are set:
#   source "$SCRIPT_DIR/../scripts/test_lib.sh"
#   source "$SCRIPT_DIR/../scripts/grate_lib.sh"
#   grate_setup "$@"
#
# Then put the grate between the runtime flags and the program under test:
#   LIND_RUN=(lind_run --enable-fpcast --env ...)
#   LIND_RUN+=("${GRATE_CMD[@]}")
#   "${LIND_RUN[@]}" usr/local/bin/<app> args...
#
# Selecting a grate (the flag wins over the env var):
#   ./<app>/run_tests.sh --grate chroot
#   LIND_GRATE=chroot ./<app>/run_tests.sh
#   make test APP=<app> GRATE=chroot
# With neither set, GRATE_CMD is empty and the suite runs exactly as before.
#
# Per-grate skips: <app>/grate_skips/<grate>.txt, one exact test name per line
# ('#' comments and blank lines ignored). Matching tests are reported as SKIP by
# is_skipped/log_skip in test_lib.sh and do not affect the exit code.

GRATE_NAME=""
GRATE_CMD=()
GRATE_SKIP_LIST=()

_grate_usage() {
    cat <<EOF
Usage: $0 [--grate <name>]

Options:
  --grate <name>   Run every test under the named grate. Also settable via LIND_GRATE.
                   Known grates:
                     chroot            chroot-grate --chroot-dir /
                     ipc               ipc-grate
                     witness           witness-grate
                     fs-routing-clamp  fs-routing-clamp --prefix /tmp, with imfs-grate
                   Any other name runs grates/<name>-grate.cwasm with no arguments.
  -h, --help       Show this help.
EOF
}

# Prints the grates installed in lindfs, for error messages.
_grate_list_installed() {
    local f found=0
    echo "Grates installed in $LINDFS_ROOT/grates:" >&2
    for f in "$LINDFS_ROOT"/grates/*.cwasm; do
        [[ -e "$f" ]] || continue
        echo "  ${f##*/}" >&2
        found=1
    done
    [[ "$found" -eq 1 ]] || echo "  (none)" >&2
}

# Sets GRATE_CMD for $GRATE_NAME. Paths are relative to lindfs, as lind_run expects.
_grate_resolve() {
    local base="${GRATE_NAME%-grate}"
    case "$base" in
        chroot)
            GRATE_CMD=(grates/chroot-grate.cwasm --chroot-dir /) ;;
        ipc)
            GRATE_CMD=(grates/ipc-grate.cwasm) ;;
        witness)
            GRATE_CMD=(grates/witness-grate.cwasm) ;;
        fs-routing-clamp)
            GRATE_CMD=(grates/fs-routing-clamp.cwasm --prefix /tmp "%{" grates/imfs-grate.cwasm "%}") ;;
        *)
            GRATE_CMD=("grates/$base-grate.cwasm") ;;
    esac
}

# Fails unless every .cwasm in GRATE_CMD exists in lindfs.
_grate_validate() {
    local arg missing=0
    for arg in "${GRATE_CMD[@]}"; do
        [[ "$arg" == *.cwasm ]] || continue
        if [[ ! -f "$LINDFS_ROOT/$arg" ]]; then
            echo "ERROR: grate '$GRATE_NAME' needs $LINDFS_ROOT/$arg, which was not found." >&2
            missing=1
        fi
    done
    if [[ "$missing" -eq 1 ]]; then
        echo "Build and install the grate from lind-wasm-example-grates first." >&2
        _grate_list_installed
        exit 1
    fi
}

_grate_load_skips() {
    local file="$SCRIPT_DIR/grate_skips/${GRATE_NAME%-grate}.txt"
    local line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && GRATE_SKIP_LIST+=("$line")
    done <"$file"
}

# Parses the suite's arguments, then resolves and validates the grate.
# Exits 1 (a precondition failure, before any test is counted) on bad input.
grate_setup() {
    if [[ -z "${LINDFS_ROOT:-}" || -z "${SCRIPT_DIR:-}" ]]; then
        echo "ERROR: grate_lib.sh: set SCRIPT_DIR and LINDFS_ROOT before calling grate_setup." >&2
        exit 1
    fi

    GRATE_NAME="${LIND_GRATE:-}"
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --grate)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "ERROR: --grate needs a grate name." >&2
                    _grate_usage >&2
                    exit 1
                fi
                GRATE_NAME="$2"
                shift 2 ;;
            --grate=*)
                GRATE_NAME="${1#--grate=}"
                shift ;;
            -h|--help)
                _grate_usage
                exit 0 ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                _grate_usage >&2
                exit 1 ;;
        esac
    done

    if [[ -z "$GRATE_NAME" || "$GRATE_NAME" == "none" ]]; then
        GRATE_NAME=""
        GRATE_CMD=()
        return 0
    fi

    _grate_resolve
    _grate_validate
    _grate_load_skips

    echo "Grate: $GRATE_NAME (${GRATE_CMD[*]})"
    if [[ "${#GRATE_SKIP_LIST[@]}" -gt 0 ]]; then
        echo "Grate skip list: ${#GRATE_SKIP_LIST[@]} test(s) from grate_skips/${GRATE_NAME%-grate}.txt"
    fi
}
