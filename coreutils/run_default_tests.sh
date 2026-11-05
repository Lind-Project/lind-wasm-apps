#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi


LINDFS="$LIND_WASM_ROOT/lindfs"
LINDFS_TESTS="$LINDFS/tests"
TEST_TIMEOUT_SECONDS="${LIND_TEST_TIMEOUT_SECONDS:-60}"

if ! [[ "$TEST_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: LIND_TEST_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

rm -rf "$LINDFS_TESTS/tmp"

# Coreutils' upstream tests refer to build-tree binaries under /src, while the
# installed Lind filesystem keeps them under /bin. Preserve those references
# with a guest-visible alias so shell and Perl tests resolve the same tools.
if [[ ! -e "$LINDFS/src" && ! -L "$LINDFS/src" ]]; then
  ln -s bin "$LINDFS/src"
elif [[ "$(readlink "$LINDFS/src" 2>/dev/null || true)" != "bin" ]]; then
  echo "ERROR: $LINDFS/src already exists and is not a symlink to bin" >&2
  exit 1
fi

# Ensure temp directory exists in the sandbox
mkdir -p "$LINDFS/tmp"

# Perl test scripts use /bin/perl, while the runnable Perl interpreter is
# staged under /usr/local/bin. The /bin/perl WASM build is not executable by
# the Lind runner, so make both guest paths resolve to the same interpreter.
if [[ -x "$LINDFS/usr/local/bin/perl" ]]; then
  ln -sfn /usr/local/bin/perl "$LINDFS/bin/perl"
fi

cp -r $SCRIPT_DIR/tests $LINDFS

# Path related fixes to test config files and test files to adapt to run within the lind-wasm ecosystem
file="$LINDFS_TESTS/test-lib.sh"
# Automake normally opens fd 9 for test logs. We invoke each script directly,
# so open it in the guest test shell and leave temp-dir cleanup to the host.
sed -i '2i exec 9>&1' "$file"
sed -i 's|cd "$test_dir_" && chmod -R u+rwx "$t_" && rm -rf "$t_" && exit $__st|cd "$test_dir_" \&\& exit $__st|' "$file"
sed -i 's|"$abs_top_builddir/src/mktemp"|bin/mktemp|g' "$file"
sed -i 's|^test_dir_=\$(pwd)|test_dir_=/tmp|' "$LINDFS_TESTS/test-lib.sh"
sed -i "s|my \$cwd = \$@ ? '\.' : Cwd::getcwd();|my \$cwd = '/tmp';|" "$LINDFS_TESTS/CuTmpdir.pm"
cp "$SCRIPT_DIR/patch_files/Coreutils.pm" "$LINDFS_TESTS/Coreutils.pm"
find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.pl" -exec sed -i 's|\$abs_top_builddir/src/|/bin/|g' {} +

# =========================================================
# ARGUMENT PARSING
# =========================================================
SKIP_BASH=0
SKIP_PERL=0
TARGET_TEST=""
GRATE_NAME=""
GRATE_CMD=()
SKIP_FILE=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --list)
            TARGET_TEST="--list"
            shift ;;
        --all)
            TARGET_TEST="--all"
            shift ;;
        --skip-bash)
            SKIP_BASH=1
            shift ;;
        --skip-perl)
            SKIP_PERL=1
            shift ;;
        --grate)
            # Take the next argument as the name
            GRATE_NAME="$2"
            shift 2 ;;
        *)
            TARGET_TEST="$1"
            shift ;;
    esac
done

# Validation: Prevent --grate being used with --list
if [[ "$TARGET_TEST" == "--list" && -n "$GRATE_NAME" ]]; then
    echo "Error: --grate cannot be used with --list"
    exit 1
fi

# Logic to set GRATE_CMD based on GRATE_NAME
# 1. Define GRATE_CMD as an array using parentheses
case "$GRATE_NAME" in
    "chroot")
        GRATE_CMD=("grates/chroot-grate.cwasm" "--chroot-dir" "/")
        SKIP_FILE="skip_chroot.txt"
	;;
    "ipc")
        GRATE_CMD=("grates/ipc-grate.cwasm")
        SKIP_FILE="skip_ipc.txt"
	;;
    "witness")
        GRATE_CMD=("grates/witness-grate.cwasm")
        SKIP_FILE="skip_witness.txt"
	;;
    "fs-routing-clamp")
        # Every space-separated item becomes its own element in the array
        GRATE_CMD=("grates/fs-routing-clamp.cwasm" "--prefix" "/tmp" "%{" "grates/imfs-grate.cwasm" "%}")
        SKIP_FILE="skip_fsrouting.txt"
	;;
    "")
        # Empty array if no grate is specified
        GRATE_CMD=()
	SKIP_FILE="skip_list.txt"
        ;;
    *)
        echo "Unknown grate: $GRATE_NAME"
        exit 1
        ;;
esac

if [[ "$TARGET_TEST" == "--list" ]]; then
    echo "Available Tests:"
    echo "---------------------------------------------------"
    find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.mk" ! -name "*.pl" | sed "s|^$LINDFS_TESTS/||" | sort
    exit 0
fi

if [[ -z "$TARGET_TEST" ]]; then
    echo "Usage:"
    echo "  $0 --list                 # Print all available tests"
    echo "  $0 --all                  # Run all tests"
    echo "  $0 misc/help-version      # Run a specific test"
    echo "  Options:"
    echo "    --grate chroot             # Run chroot grate"
    echo "    --grate ipc	 	       # Run ipc grate"
    echo "    --grate witness            # Run witness grate"
    echo "    --grate fs-routing-clamp   # Run fs-routing-clamp with imfs grate"
    echo "    --skip-bash                # Skip all Bash tests"
    echo "    --skip-perl                # Skip all Perl tests"
    exit 1
fi

# Determine which tests to run
TESTS_TO_RUN=()
if [[ "$TARGET_TEST" == "--all" ]]; then
    while IFS= read -r t; do
        TESTS_TO_RUN+=("$t")
    done < <(find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.mk" ! -name "*.pl" | sed "s|^$LINDFS_TESTS/||" | sort)
else
    TESTS_TO_RUN=("$TARGET_TEST")
fi

# Set Sandbox Environment Variables
BUILT_PROGS=$(ls "$LINDFS/bin" | tr "\n" " ")
export built_programs="$BUILT_PROGS"
export CONFIG_HEADER="/lib/config.h"
export TMPDIR="/tmp"
export abs_top_builddir="/"
export abs_top_srcdir="/"
export abs_srcdir="/tests"
export PATH="/bin:/usr/local/bin:/usr/bin"
export srcdir="/tests"
export srcdir="/home/lind/lind-wasm/lindfs/tests"

# lind-boot does not auto-inherit the host environment into the cage; the guest
# environ is built only from --env flags. Forward the vars perl tests read.
ENV_FORWARD=(--env abs_top_builddir --env abs_top_srcdir --env abs_srcdir
             --env PATH --env CONFIG_HEADER --env TMPDIR --env built_programs)

# Tracking variables for the summary
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0

# Loop through our target(s)
for CURRENT_TEST in "${TESTS_TO_RUN[@]}"; do
    HOST_TEST_PATH="$LINDFS_TESTS/$CURRENT_TEST"

    if [[ -f "$SKIP_FILE" ]] && grep -Fxq "$CURRENT_TEST" "$SKIP_FILE"; then
        echo "Test $CURRENT_TEST is in the skip list. Skipping..."
        continue
    fi

    if [[ ! -f "$HOST_TEST_PATH" ]]; then
        echo "Error: Test '$CURRENT_TEST' not found in sandbox at $HOST_TEST_PATH"
        continue
    fi

    SANDBOX_PATH="/tests/$CURRENT_TEST"

    # Check shebang to dispatch to bash or perl
    read -r first_line < "$HOST_TEST_PATH" || true

    if [[ "$first_line" == *"#!/usr/bin/perl"* ]]; then
        if [[ "$SKIP_PERL" -eq 1 ]]; then
            printf "[\033[33mSKIP\033[0m] %s (Perl test skipped via flag)\n" "$CURRENT_TEST"
            ((TOTAL_SKIP++)) || true
            continue
        fi
        
        T_BASE=$(basename "$CURRENT_TEST")
	if [[ ${#GRATE_CMD[@]} -gt 0 ]]; then	
		CMD=(lind_run --enable-fpcast "${ENV_FORWARD[@]}" "${GRATE_CMD[@]}" usr/local/bin/perl -w -I/lib -I/tests -MCoreutils -M"CuTmpdir qw($T_BASE)" -- "$SANDBOX_PATH")
        else
		CMD=(lind_run --enable-fpcast "${ENV_FORWARD[@]}" usr/local/bin/perl -w -I/lib -I/tests -MCoreutils -M"CuTmpdir qw($T_BASE)" -- "$SANDBOX_PATH")
	fi
else
        if [[ "$SKIP_BASH" -eq 1 ]]; then
            printf "[\033[33mSKIP\033[0m] %s (Bash test skipped via flag)\n" "$CURRENT_TEST"
            ((TOTAL_SKIP++)) || true
            continue
        fi
        sed -i 's/$srcdir/tests/g' "$HOST_TEST_PATH"
   	if [[ ${#GRATE_CMD[@]} -gt 0 ]]; then
		CMD=(lind-wasm --enable-fpcast "${ENV_FORWARD[@]}" "${GRATE_CMD[@]}" bin/bash "$SANDBOX_PATH")
	else
		CMD=(lind-wasm --enable-fpcast "${ENV_FORWARD[@]}" bin/bash "$SANDBOX_PATH")
	fi	
   fi

    echo "==================================================="
    echo "Executing: $CURRENT_TEST"
    echo "Sandbox Path: $SANDBOX_PATH"
    echo "==================================================="

    set +e
    timeout --signal=TERM --kill-after=2s "${TEST_TIMEOUT_SECONDS}s" "${CMD[@]}"
    EXIT_CODE=$?
    set -e

    # Tests share the Lind guest's /tmp. Remove leftovers as the host because
    # some guest chmod operations depend on syscalls not available in Lind.
    find "$LINDFS/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true

    echo "==================================================="
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        printf "Result: $SANDBOX_PATH [\033[32mPASS\033[0m] (Exit 0)\n"
        ((TOTAL_PASS++)) || true
    elif [[ "$EXIT_CODE" -eq 77 ]]; then
        printf "Result: $SANDBOX_PATH [\033[33mSKIP\033[0m] (Exit 77)\n"
        ((TOTAL_SKIP++)) || true
    elif [[ "$EXIT_CODE" -eq 124 ]]; then
        printf "Result: [\033[31mFAIL\033[0m] (Timed out after %s seconds)\n" "$TEST_TIMEOUT_SECONDS"
        ((TOTAL_FAIL++)) || true
    else
        printf "Result: [\033[31mFAIL\033[0m] (Exit %d)\n" "$EXIT_CODE"
        ((TOTAL_FAIL++)) || true
    fi
done

# Print the final tally if running the whole suite
if [[ "$TARGET_TEST" == "--all" ]]; then
    echo "==================================================="
    echo "                  TEST SUMMARY                     "
    echo "==================================================="
    printf " [\033[32mPASS\033[0m] : %d\n" "$TOTAL_PASS"
    printf " [\033[31mFAIL\033[0m] : %d\n" "$TOTAL_FAIL"
    printf " [\033[33mSKIP\033[0m] : %d\n" "$TOTAL_SKIP"
    echo "==================================================="
fi

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
