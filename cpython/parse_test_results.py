#!/usr/bin/env python3
"""
produce_correctness_results.py

Parses a CPython 'make test' log and reports per-module stats for ALL modules.

Usage:
    python produce_correctness_results.py <log_file> --tests-csv tests.csv [--output results.csv]

tests.csv format:
    module,total_tests

Output columns:
    Module, Status, Total_tests, Total_tests_run, Tests_succeeded,
    Tests_failed, Tests_skipped

Rules per status:
    PASSED  → total_tests_run = csv_total, succeeded = csv_total, rest = 0
    SKIPPED → total_tests_run = 0, skipped = csv_total, rest = 0
    FAILED  → parse detailed block:
              total_tests_run = Ran N
              succeeded       = unique '... ok' lines
              skipped         = unique '... skipped' lines
              failed          = unique ERROR:/FAIL: headers (excl. lifecycle)
                                + not_run (setUpClass victims = Ran N - ok - failed - skipped)
              i.e. failed absorbs tests that never got a chance to run
"""

import re
import csv
import argparse


def load_tests_csv(path):
    result = {}
    with open(path, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            keys      = {k.strip().lower(): k for k in row}
            mod_col   = keys.get('module')
            total_col = next((keys[k] for k in keys if 'test' in k), None)
            if mod_col and total_col:
                module = row[mod_col].strip()
                try:
                    result[module] = int(row[total_col].strip())
                except ValueError:
                    pass
    return result


def parse_log(log_path, tests_map):
    with open(log_path, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()

    LOAD_AVG_RE    = re.compile(r'load avg')
    MODULE_RE      = re.compile(r'\[[\s\d/]+\]\s+(\S+)\s+(passed|skipped|failed)')
    LIFECYCLE      = {'setUpClass', 'tearDownClass', 'setUpModule', 'tearDownModule'}
    TEST_RESULT_RE = re.compile(r'^(\S+)\s+\(.*?\)\s+\.\.\.\s+(\S+)')

    progress = []
    for i, line in enumerate(lines):
        if 'load avg' not in line:
            continue
        m = MODULE_RE.search(line)
        if m:
            progress.append((i, m.group(1), m.group(2)))

    results = []

    for idx, (start, module, status) in enumerate(progress):
        total_tests = tests_map.get(module)

        # ---- PASSED -------------------------------------------------------
        if status == 'passed':
            results.append({
                'module':          module,
                'status':          'passed',
                'total_tests':     total_tests,
                'total_tests_run': total_tests,
                'tests_succeeded': total_tests,
                'tests_failed':    0,
                'tests_skipped':   0,
            })
            continue

        # ---- SKIPPED -------------------------------------------------------
        if status == 'skipped':
            results.append({
                'module':          module,
                'status':          'skipped',
                'total_tests':     total_tests,
                'total_tests_run': 0,
                'tests_succeeded': 0,
                'tests_failed':    0,
                'tests_skipped':   total_tests,
            })
            continue

        # ---- FAILED -------------------------------------------------------
        end = None
        for i in range(start + 1, len(lines)):
            if LOAD_AVG_RE.search(lines[i]):
                end = i
                break
        if end is None:
            end = len(lines)

        block = lines[start:end]

        # total_tests_run = Ran N
        total_run = None
        for line in block:
            m = re.match(r'^Ran (\d+) tests?', line.strip())
            if m:
                total_run = int(m.group(1))
                break

        # Individual results — first occurrence per test name
        seen = {}
        for line in block:
            m = TEST_RESULT_RE.match(line.strip())
            if m:
                name, result = m.group(1), m.group(2)
                if name not in seen:
                    seen[name] = result

        tests_succeeded = sum(1 for r in seen.values() if r == 'ok')
        tests_skipped   = sum(1 for r in seen.values() if r == 'skipped')

        # Unique failed tests from ERROR:/FAIL: headers, excluding lifecycle
        failed_tests = set()
        for line in block:
            m = re.match(r'^(ERROR|FAIL):\s+(\S+)', line)
            if m and m.group(2) not in LIFECYCLE:
                failed_tests.add(m.group(2))
        tests_failed = len(failed_tests)

        # Add not_run (setUpClass victims) into failed
        # not_run = Ran N - succeeded - failed - skipped
        if total_run is not None:
            not_run = max(total_run - tests_succeeded - tests_failed - tests_skipped, 0)
            tests_failed += not_run

        results.append({
            'module':          module,
            'status':          'failed',
            'total_tests':     total_tests,
            'total_tests_run': total_run,
            'tests_succeeded': tests_succeeded,
            'tests_failed':    tests_failed,
            'tests_skipped':   tests_skipped,
        })

    return results


def write_csv(results, output_path):
    fieldnames = ['Module', 'Status', 'Total_tests', 'Total_tests_run',
                  'Tests_succeeded', 'Tests_failed', 'Tests_skipped']
    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in results:
            def v(x): return '' if x is None else x
            writer.writerow({
                'Module':           r['module'],
                'Status':           r['status'],
                'Total_tests':      v(r['total_tests']),
                'Total_tests_run':  v(r['total_tests_run']),
                'Tests_succeeded':  v(r['tests_succeeded']),
                'Tests_failed':     v(r['tests_failed']),
                'Tests_skipped':    v(r['tests_skipped']),
            })
    print(f"Wrote {len(results)} rows to {output_path}")


def print_table(results):
    header = (f"{'Module':<45} {'Status':<8} {'Total':>7} {'Run':>7} "
              f"{'Succeeded':>10} {'Failed':>7} {'Skipped':>8}")
    print(header)
    print('-' * len(header))
    for r in results:
        print(
            f"{r['module']:<45} "
            f"{r['status']:<8} "
            f"{str(r['total_tests'] or '?'):>7} "
            f"{str(r['total_tests_run'] if r['total_tests_run'] is not None else '?'):>7} "
            f"{str(r['tests_succeeded'] if r['tests_succeeded'] is not None else '?'):>10} "
            f"{str(r['tests_failed'] if r['tests_failed'] is not None else '?'):>7} "
            f"{str(r['tests_skipped'] if r['tests_skipped'] is not None else '?'):>8}"
        )

    by_status = {}
    for r in results:
        by_status[r['status']] = by_status.get(r['status'], 0) + 1
    # Column totals
    total_tests     = sum(r['total_tests']     or 0 for r in results)
    total_run       = sum(r['total_tests_run'] or 0 for r in results)
    total_succeeded = sum(r['tests_succeeded'] or 0 for r in results)
    total_failed    = sum(r['tests_failed']    or 0 for r in results)
    total_skipped   = sum(r['tests_skipped']   or 0 for r in results)

    print()
    print('-' * len(header))
    print(f"Total modules: {len(results)} — " +
          ", ".join(f"{s}: {c}" for s, c in sorted(by_status.items())))
    print('-' * len(header))
    print(f"Total tests:            {total_tests}")
    print(f"Total tests run:        {total_run}")
    print(f"Total tests succeeded:  {total_succeeded}")
    print(f"Total tests failed:     {total_failed}")
    print(f"Total tests skipped:    {total_skipped}")

    print()


def main():
    parser = argparse.ArgumentParser(
        description='Parse a CPython make test log and report stats for all modules.'
    )
    parser.add_argument('log_file')
    parser.add_argument('--tests-csv', required=True, metavar='FILE')
    parser.add_argument('--output', default='test_results.csv')
    args = parser.parse_args()

    print(f"Loading test counts from {args.tests_csv} ...")
    tests_map = load_tests_csv(args.tests_csv)
    print(f"  Loaded {len(tests_map)} modules.\n")

    print(f"Parsing {args.log_file} ...")
    results = parse_log(args.log_file, tests_map)
    print(f"  Found {len(results)} modules.\n")

    print_table(results)
    print()
    write_csv(results, args.output)


if __name__ == '__main__':
    main()
