# Applications on LFI (`lfi-threei` branch)

Builds selected `lind-wasm-apps` programs for the LFI sandbox (the
[`lind-lfi`](../../lind-lfi) repository: LFI runtime plus Lind's 3i/grate layer) instead of
wasm32, and runs them — directly and with grates in front — using the apps' own test scripts.
**Experimental** (`v0.1.0-experimental`): see "Known issues" below and `lind-lfi/docs/KNOWN_ISSUES.md`.
The application sources and everything else on this branch are unchanged from upstream; this
directory is the whole addition.

## Prerequisites

A built `lind-lfi` checkout (its `README.md`: `scripts/bootstrap.sh`, then
`meson setup build && ninja -C build` in `lfi-runtime`, and `make rust` plus `make` in
`lfi-runtime/threei/grates` for the grates), then:

    export LFI_ROOT=/path/to/lind-lfi          # or set LFI_TC and LFI_RT individually
    source $LFI_ROOT/scripts/env.sh            # LFI compilers and tools on PATH

Other settings (see `env.sh`): `BUILD` (default `<repo>/build-lfi`; `rootfs/` under it becomes the
sandbox's `/`), `RUN` (the `lfi-3i-run` binary), `GRATES` (default
`$LFI_RT/threei/grates/out`), `JOBS`.

## Supported applications

`sed`, `grep`, `gawk`, `diffutils`, `make`, `coreutils` (the `lind-wasm-apps` versions) and
`zlib`. Nothing else on the branch is built for LFI.

    cd lfi
    make                      # build all of the above into ../build-lfi/rootfs
    make APPS="sed grep"      # or a subset
    make test                 # smoke tests: directly, then with the strace grate in front

How the build differs from the wasm pipeline:

* **Toolchain:** the LFI clang/musl (`env.sh`); no sysroot merging, no `wasm-opt`.
* **Out-of-tree builds** from a copy of each source tree (`build-app.sh`); files modified in a
  local working tree are restored from `HEAD` in the copy, so the build does not depend on local
  edits.
* **configure runs its test programs inside the sandbox** (`cc-run.sh` turns every linked
  executable into a launcher for `lfi-3i-run`), so runtime checks measure musl's behaviour.
* **Not built:** documentation, man pages, anything that runs the fresh program on the host.
* **Deviations, per app** (commented in `build-app.sh`): gnulib in coreutils predates musl (small
  shims in `overlay/`); `libstdbuf` (`LD_PRELOAD`) cannot work; `gawk` uses its portable `ctz`
  because the verifier cannot decode `rep bsf` on a `%gs` operand; GNU make's bundled glob needs one
  warning relaxed. Disabled upstream features are those that need documentation tools, `LD_PRELOAD`,
  or a mount table.

## Running the apps' own tests, with and without grates

    lfi/run-tests.sh sed grep awk make coreutils                       # direct
    LFI_GRATES="/grates/strace-grate" lfi/run-tests.sh sed grep awk    # a grate in front of every program

The apps' `run_tests.sh` scripts run **unmodified**. `run-tests.sh` builds a stand-in lind-wasm tree
under `build-lfi/lindroot/` (`lindfs/` is the rootfs, a `lind_run` that runs a program from it with
`lfi-3i-run`, and a pass-through `sudo`). `LFI_GRATES` is a chain of grates (paths inside the
rootfs) put in front of every program; `LFI_STDOUT_FILTER` drops banner lines of chatty grates.

A second, finer-grained mode builds every program as a launcher so the apps' *upstream* suites can
drive them: `lfi/build-check.sh coreutils`, `lfi/run-check.sh coreutils [tests...]`.

Things to know:

* The grates exit with their cage's status (and `128+signal` if it was killed), so a program's
  failure reaches the caller through any C or Rust example grate. (Earlier descriptions of the C
  grates ignoring the status no longer apply.)
* `launch.sh` runs with the harness's `PATH`; it uses a fixed `PATH` and absolute tool paths, and
  has a depth guard against runaway recursion.
* `run-tests.sh`/`run-check.sh` cap the processes they can create, kill their session at the end and
  run `pkill -x lfi-3i-run`, so do not run them while other `lfi-3i-run` jobs matter to you.
* With a grate in front, the cage's `argv[0]` is the path the grate execs, so tests that compare
  messages containing it can differ.

## Results

RESULTS_PLACEHOLDER

## Known issues

* The runtime and grate defects in `lind-lfi/docs/KNOWN_ISSUES.md` apply; passing these suites does
  not establish compatibility beyond the exercised behaviour.
* Only the suites above were run; `bash`, `curl`, `openssl`, `cpython`, `postgres`, `git` and the
  rest of the repository are not built for LFI by this branch.
* The two `coreutils` failures (`ln`, `df`) also fail on real Lind (wasm).
