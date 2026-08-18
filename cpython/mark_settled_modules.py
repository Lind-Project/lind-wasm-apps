#!/usr/bin/env python3
"""
mark_settled_modules.py

Read a regrtest log. For every module whose worker completed *without dying*
(i.e. status is 'passed' / 'failed (N errors, M failures)' / 'skipped' — not
'worker non-zero exit code' / 'timed out' / 'Killed by signal'), append its
name to a settled-modules file. Subsequent iterations can `-x` these to skip
them entirely and shrink the suite.

Designed to run alongside update_skip_files.py in the iteration loop:

    update_skip_files.py    --log $LOG ...   # adds killer tests
    mark_settled_modules.py --log $LOG ...   # adds settled modules

Exit codes:
    0  → nothing new to add (no newly-settled modules in this log)
    1  → at least one new module was appended

Inputs:
    --log <path>             Regrtest log to scan
    --settled-file <path>    File to append settled module names to (one per line)
    --dry-run                Print what would be added without modifying the file
"""

import argparse
import os
import re
import sys
import time


# Same boundary regex used by the other scripts in this set
BOUNDARY_RE = re.compile(r'load avg:.*\]\s+(\S+)\s+(.+?)(?:\s+--.*)?$')
DEATH_RE = re.compile(r'worker non-zero exit code|timed out|Killed by signal')


def load_existing(path):
    out = set()
    if path and os.path.isfile(path):
        with open(path) as f:
            for line in f:
                line = line.split('#', 1)[0].strip()
                if line:
                    out.add(line)
    return out


def find_settled(log_path):
    """Return (settled_modules, crashed_modules) discovered in the log.

    A module is settled iff its boundary line shows a non-death status —
    i.e. the worker finished. A module that crashed in this run is NOT
    settled and remains a candidate for the next iteration.
    """
    settled = set()
    crashed = set()
    with open(log_path, errors='replace') as f:
        for raw in f:
            line = raw.rstrip()
            bm = BOUNDARY_RE.search(line)
            if not bm:
                continue
            mod = bm.group(1)
            status = bm.group(2).strip()
            if DEATH_RE.search(status):
                crashed.add(mod)
            else:
                settled.add(mod)
    # A module that ran cleanly in this log AND ALSO crashed somewhere else
    # in the same log shouldn't be settled — be conservative.
    settled -= crashed
    return settled, crashed


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", required=True)
    ap.add_argument("--settled-file", required=True,
                    help="Will be created if missing; appended in place otherwise")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.log):
        sys.stderr.write(f"ERROR: log not found: {args.log}\n")
        sys.exit(2)

    existing = load_existing(args.settled_file)
    settled, crashed = find_settled(args.log)
    new = sorted(settled - existing)

    e = sys.stderr.write
    e(f"\n=== {os.path.basename(args.log)} — settled-modules pass ===\n")
    e(f"  modules with healthy worker:   {len(settled)}\n")
    e(f"  modules with worker death:     {len(crashed)}\n")
    e(f"  already marked settled:        {len(settled & existing)}\n")
    e(f"  newly settled this iteration:  {len(new)}\n")

    if not new:
        e("\n  No newly-settled modules — settled list unchanged.\n")
        sys.exit(0)

    if args.dry_run:
        e("\n  Would append (dry-run):\n")
        for m in new:
            e(f"    {m}\n")
        sys.exit(1)

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    header_needed = not os.path.isfile(args.settled_file)
    with open(args.settled_file, "a") as f:
        if header_needed:
            f.write("# Modules whose worker completed cleanly — safe to -x in subsequent iterations.\n")
            f.write("# One module per line. Blank lines and `# ...` comments are ignored.\n")
        f.write(f"\n# ─── settled in {os.path.basename(args.log)} (appended {timestamp}) ─\n")
        for m in new:
            f.write(m + "\n")
    e(f"\n  Appended {len(new)} module names to {args.settled_file}\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
