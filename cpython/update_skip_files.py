#!/usr/bin/env python3
"""
update_skip_files.py

Read a regrtest log, find tests/modules whose failure killed a worker, and
APPEND them in place to your skip files. Designed for use inside a loop:

    until python3 update_skip_files.py --log latest.log \\
            --tests-file cpython_skip_tests.txt \\
            --modules-file cpython_skip_modules.txt; do
        ./run_tests.sh > latest.log 2>&1
    done

Exit codes:
    0 → nothing to add (CONVERGED)
    1 → new entries were appended; another iteration is warranted
    2 → bad arguments or unreadable files (don't loop)

Use --dry-run to see what would be appended without modifying the files.
"""

import argparse
import os
import re
import sys
import time


BOUNDARY_RE = re.compile(r'load avg:.*\]\s+(\S+)\s+(.+?)(?:\s+--.*)?$')
TEST_HEADER_RE = re.compile(r'^[A-Za-z_][A-Za-z_0-9]*\s+\((test[\w.]+)\)')
RAN_RE = re.compile(r'^Ran \d+ tests? in [\d.]+s')
FINAL_RE = re.compile(r'^(OK(\s+\(.*\))?|FAILED(\s+\(.*\))?)\s*$')
DEATH_RE = re.compile(r'worker non-zero exit code|timed out|Killed by signal')


def load_skip(path):
    out = set()
    if path and os.path.isfile(path):
        with open(path) as f:
            for line in f:
                line = line.split('#', 1)[0].strip()
                if line:
                    out.add(line)
    return out


def parse_deaths(log_path):
    deaths = []
    in_block = False
    block_mod = block_status = last_test = None
    seen_ran = seen_final = False

    def flush():
        nonlocal in_block, block_mod, block_status, last_test, seen_ran, seen_final
        deaths.append({
            "module": block_mod,
            "status": block_status,
            "last_test": last_test,
            "completed_cleanly": seen_ran and seen_final,
        })
        in_block = False
        block_mod = block_status = last_test = None
        seen_ran = seen_final = False

    with open(log_path, errors='replace') as f:
        for raw in f:
            line = raw.rstrip()
            bm = BOUNDARY_RE.search(line)
            if bm:
                if in_block:
                    flush()
                status = bm.group(2).strip()
                if DEATH_RE.search(status):
                    in_block = True
                    block_mod = bm.group(1)
                    block_status = status
                continue
            if not in_block:
                continue
            tm = TEST_HEADER_RE.match(line)
            if tm:
                last_test = tm.group(1)
                continue
            if RAN_RE.match(line):
                seen_ran = True
                continue
            if FINAL_RE.match(line):
                seen_final = True
                continue
    if in_block:
        flush()
    return deaths


def append_block(path, new_lines, header):
    """Append a banner + new entries to `path`. Creates the file if missing."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(path, "a") as f:
        f.write(f"\n# ─── {header} (appended {timestamp}) ─\n")
        for line in sorted(set(new_lines)):
            f.write(line + "\n")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", required=True)
    ap.add_argument("--tests-file", required=True,
                    help="Skip file for individual tests (--ignorefile format)")
    ap.add_argument("--modules-file", required=True,
                    help="Skip file for whole-module excludes (one module per line)")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print what would be added; do not modify files")
    args = ap.parse_args()

    if not os.path.isfile(args.log):
        sys.stderr.write(f"ERROR: log not found: {args.log}\n")
        sys.exit(2)

    existing_tests = load_skip(args.tests_file)
    existing_modules = load_skip(args.modules_file)

    deaths = parse_deaths(args.log)

    new_tests, new_modules = set(), set()
    fp_count = re_test = re_mod = 0

    for d in deaths:
        if d["completed_cleanly"]:
            fp_count += 1
            continue
        if d["last_test"] is None:
            if d["module"] in existing_modules:
                re_mod += 1
            else:
                new_modules.add(d["module"])
            continue
        if d["last_test"] in existing_tests:
            re_test += 1
        else:
            new_tests.add(d["last_test"])

    # ── Report ──
    e = sys.stderr.write
    e(f"\n=== {os.path.basename(args.log)} ===\n")
    e(f"  worker deaths:                 {len(deaths)}\n")
    e(f"  new individual tests:          {len(new_tests)}\n")
    e(f"  new module-level excludes:     {len(new_modules)}\n")
    e(f"  re-crashes (already in file):  {re_test + re_mod}\n")
    e(f"  false positives (post-OK):     {fp_count}\n")

    if re_test + re_mod > 0:
        e("\n  WARNING: Some crashing tests are already in the skip files but still\n")
        e("           crashed. Your --ignorefile / -x args probably aren't reaching\n")
        e("           regrtest (truncation, Make TESTOPTS issue). Verify with:\n")
        e("              grep -m1 '^+ .*-m test' " + args.log + "\n")

    if not new_tests and not new_modules:
        e("\n  CONVERGED — no new killer tests/modules in this log.\n")
        sys.exit(0)

    if args.dry_run:
        e("\n  Would append the following (dry-run, no files modified):\n")
        if new_tests:
            e(f"\n    to {args.tests_file}:\n")
            for t in sorted(new_tests):
                e(f"      {t}\n")
        if new_modules:
            e(f"\n    to {args.modules_file}:\n")
            for m in sorted(new_modules):
                e(f"      {m}\n")
        e("\n  (re-run without --dry-run to actually append)\n")
        sys.exit(1)

    if new_tests:
        append_block(args.tests_file, new_tests,
                     f"killer tests found in {os.path.basename(args.log)}")
        e(f"\n  Appended {len(new_tests)} test patterns to {args.tests_file}\n")
    if new_modules:
        append_block(args.modules_file, new_modules,
                     f"module-level killers found in {os.path.basename(args.log)}")
        e(f"  Appended {len(new_modules)} module names to {args.modules_file}\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
