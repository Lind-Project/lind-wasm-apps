# Testing

This document defines the contract every `<app>/run_tests.sh` must satisfy. It exists so
that:

- new apps can add a test suite without guessing the shape,
- `make test` and CI can treat every app's suite identically,
- and skipping/failing is unambiguous to both humans and automation.

For the grate test suites in `lind-wasm-example-grates`, see that repo's
`test/run_tests.sh` + `test/grates_test.toml` — the same principles apply there via a
declarative TOML config instead of hand-written bash.

## How tests are run

```bash
make test                       # run every app in TESTABLE_APPS
APP=bash make test               # run one app
APP="bash git grep" make test    # run a subset
```

`Makefile`'s `test` target loops over `$(APP)` and, for each one, checks whether
`<app>/run_tests.sh` exists and is executable. If it isn't, the app is skipped with
`[SKIP] $app: missing run_tests.sh` — this is not a failure, and `make test` still exits 0
if every app that *does* have a suite passes.

Tests assume the app is already built and installed:

```bash
make <app>
make install-<app>
make check-build APP=<app>   # optional: verifies expected-binaries.txt landed in build/<app>/
make test APP=<app>
```

## Requirements for `<app>/run_tests.sh`

### 1. Invocation

- Lives at `<app>/run_tests.sh`, executable (`chmod +x`), `#!/usr/bin/env bash` shebang.
- Runs standalone with no required arguments: `./bash/run_tests.sh` must work directly, not
  just through `make test`.
- Resolves its own location instead of assuming the caller's CWD:
  ```bash
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  ```
- Respects `LIND_WASM_ROOT` if set; falls back to the conventional sibling layout
  (`~/lind-wasm`) if not.

### 2. Preconditions — fail fast, before any test runs

- Verify the binary is staged (`build/<app>/usr/local/bin/...`). If missing, `exit 1` with
  the exact `make` command needed to fix it.
- Verify the binary is installed into `lindfs`. Same treatment if missing.
- These checks happen *before* any pass/fail counter starts — "not built" must never be
  reported as "0 failures."

### 3. Execution

- Each test case is an independent, named assertion — not one script where a single
  failure aborts everything else. One failing test must not prevent later tests from
  running.
- Every invocation of the app under test goes through the Lind runtime (`lind_run` /
  `lind-wasm`, with `--enable-fpcast` for apps that need fpcast-emu). Never call the
  natively-built binary directly — that validates the wrong artifact.
- Every test has a timeout (`timeout Ns ...`). A hang in the sandboxed runtime must become
  a bounded failure, not a stuck CI job. Pick a per-suite default appropriate to the app
  (bash's suite uses 3s per test; a heavier app like cpython or git should use more).
- Tests are idempotent and self-contained: fixtures are created under a scratch path
  (`$LINDFS_ROOT/tests/<app>/...` or `mktemp`) and don't depend on state left by a prior
  run or a prior test in the same run.

### 4. Cleanup

- Any fixtures written into `lindfs` or `/tmp` are removed at the end of the run
  (or via `trap`), regardless of pass/fail outcome, so re-running the suite twice gives
  identical results.

### 5. Skip mechanism

- **App-level skip** is structural: an app with no meaningful tests simply doesn't ship
  `run_tests.sh`. Don't ship a script that always exits 0 as a stand-in for "no tests."
- **Test-level skip** (suppressing one known-broken assertion within a suite) uses a
  distinct `SKIPPED` counter, separate from `PASS`/`FAIL`, and must not affect the exit
  code. Mirror the grates runner's pattern (`log_skip`, yellow-coded, tallied but excluded
  from the pass/fail decision). Optionally honor a `SKIP_TESTS="name1 name2"` env var so a
  specific case can be suppressed without editing the script.
  - **Status: not yet implemented in any app suite** — see the tracking issue.

### 6. Result / exit-code contract

- Exactly two outcomes: `exit 0` (every non-skipped test passed) or `exit 1` (at least one
  failure, or a precondition wasn't met). No other exit codes.
- The exit code is the source of truth. Callers (Makefile, CI) must never need to parse
  stdout to determine pass/fail.

### 7. Output

- Each test result line is prefixed consistently (`PASS:` / `FAIL:` / `SKIP:`) so it's
  greppable.
- Failures print expected vs. actual, not just "FAIL":
  ```
  FAIL: case-insensitive (-i)
       expected: 4 lines
       actual  : 2 lines
  ```
- End with a summary block: total / passed / failed / skipped.

### 8. Isolation between apps

- A suite must not depend on another app's suite having run first, except through the
  declared *build* dependency graph in the `Makefile` (e.g. `git` needing `zlib`/`openssl`
  staged — a build dependency, not a test dependency).
  `APP="bash git grep" make test` must produce the same per-app results as running each
  app's suite alone.

### 9. Build-variant coverage (`LIND_DYLINK`)

- Some apps can be built either statically or dynamically via `LIND_DYLINK=1` on their
  `compile_<app>.sh` (e.g. `bash/compile_bash.sh`, `curl/compile_curl.sh`,
  `grep/compile_grep.sh`, `coreutils/compile_coreutils.sh`). A dynamically-linked build
  needs its shared library dependencies preloaded into the sandbox at run time.
- If an app's `compile_<app>.sh` supports `LIND_DYLINK`, its `run_tests.sh` should honor
  the same env var and switch its `lind_run`/`lind-wasm` invocation to
  `--preload env=lib/<name>.so` for each shared dependency when `LIND_DYLINK=1` —
  mirroring `curl/run_tests.sh` and `git/run_tests.sh`:
  ```bash
  LIND_DYLINK="${LIND_DYLINK:-0}"
  if [[ "$LIND_DYLINK" == "1" ]]; then
      LIND_RUN+=(--preload env=lib/libz.so --preload env=lib/libcrypto.so --preload env=lib/libssl.so)
  fi
  ```
- `make test` alone only exercises the default (`LIND_DYLINK=0`, static) path. Exercising
  the dylink path is opt-in today (`LIND_DYLINK=1 make test`) and isn't wired into any CI
  matrix.
- **Status: not yet implemented in `bash`, `coreutils`, or `grep`** — each of these can be
  *built* with `LIND_DYLINK=1`, but their `run_tests.sh` has no `LIND_DYLINK` handling, so
  that build variant is currently untested. See the tracking issue.

## Reference implementations

- `grep/run_tests.sh` — precondition checks, fixture creation/cleanup, PASS/FAIL summary.
- `bash/run_tests.sh` — `assert(description, expected, cmd)` pattern, per-test timeout.
- `lind-wasm-example-grates/test/run_tests.sh` — config-driven (TOML) runner with a real
  `SKIPPED` tally; the model for requirement 5 once ported here.
- `curl/run_tests.sh` / `git/run_tests.sh` — `LIND_DYLINK`-conditional `--preload` handling;
  the model for requirement 9 once ported to `bash`, `coreutils`, and `grep`.
