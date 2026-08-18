#!/usr/bin/env bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi
cd $APPS_ROOT
LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"
  START=0
  MAX_ITERS=50                            # bump from 10 → 25
  LOG_DIR=$1
 
  i=$START
  while (( i < START + MAX_ITERS )); do
      LOG="$LOG_DIR/wasm${i}.log"
      echo "─── iteration $i  →  $LOG ───"
      ps -ef | grep lind-boot | grep python | awk '{print $2}' | sudo xargs kill -9
      BUILD_MODE=linux LIND_DYLINK=1 APP=cpython make test TESTTIMEOUT=120 | tee "$LOG"

      # ── 1. Harvest new killer tests ──
      python3 $SCRIPT_DIR/update_skip_files.py \
          --log "$LOG" \
          --tests-file $SCRIPT_DIR/cpython_skip_tests.txt \
          --modules-file $SCRIPT_DIR/cpython_skip_modules.txt
      rc_killer=$?

      # ── 2. Harvest newly settled modules ──
      python3 $SCRIPT_DIR/mark_settled_modules.py \
          --log "$LOG" \
          --settled-file $SCRIPT_DIR/cpython_settled_modules.txt
      rc_settled=$?
  
      # Bail on unexpected exit codes
      if (( rc_killer != 0 && rc_killer != 1 )); then
          echo "✗ update_skip_files.py error (rc=$rc_killer), stopping."
          exit $rc_killer
      fi
      if (( rc_settled != 0 && rc_settled != 1 )); then
          echo "✗ mark_settled_modules.py error (rc=$rc_settled), stopping."
          exit $rc_settled
      fi

      # Converged only when BOTH passes added nothing
      if (( rc_killer == 0 && rc_settled == 0 )); then
          echo "✓ CONVERGED at iteration $i — every module classified."
          break
      fi
      sudo rm -rf $LINDFS_ROOT/tmp/*
      sudo rm -rf $LINDFS_ROOT/test_python*
      sudo rm -rf $LINDFS_ROOT/\@test*
      sudo pkill -TERM -f 'lind-boot'

      ((i++))
  done

  if (( i >= START + MAX_ITERS )); then
      echo "⚠ Did not converge after $MAX_ITERS iterations. Investigate $LOG."
  fi

