# lind-mpk / lind-wasm compatibility assessment

This directory measures which lind-wasm-apps run under lind-wasm, both as
WebAssembly (the regular `make <app>` builds) and under the native
**MPK backend** (`lind_compile --mpk`: x86-64 ELF programs linked
against lind's glibc, rewritten by `gsfork-elf`, and run by `lind-boot` with
PKRU-based isolation instead of WebAssembly).

The latest results:

- [results/comparison.md](results/comparison.md): WASM and MPK verdicts side by side.
- [results/report.md](results/report.md): the MPK report.
- [results/wasm/report.md](results/wasm/report.md): the WASM report.

Each report has a `report.json` next to it, and logs are in `logs/<app>/`.

To set up a fresh machine from scratch (repos, container, glibc, lind-boot, rewriter)
and run the large gcc `cc1` rewrite, see [GCC-EVAL-HANDOFF.md](GCC-EVAL-HANDOFF.md).

## Reproducing

Inside a lind dev container that mounts this repo (as user `lind`), from the repo root:

```sh
make experiments                        # all apps except gcc and clang: WASM, then MPK, then comparison.md
make experiments EXP_APPS="sed nginx"   # selected apps only (merged into the existing reports)
make experiments-wasm                   # only the WASM side; experiments-mpk for only the MPK side
make experiments EXCLUDE= ASSESS_ARGS="--rebuild --no-upstream"   # include gcc/clang, pass assess.py flags
```

These targets wrap `python3 mpk/assess.py --mode {both,wasm,mpk} [apps...] [--exclude APP...]`.
Runs that name or exclude apps update only those apps; the other apps keep
their earlier results and logs (so gcc/clang results from another machine stay
in the reports). Only `assess.py` without app arguments or `--exclude` starts
the reports from scratch.
`python3 mpk/assess.py --help` lists the timeouts, the work directories and the other options.

From the host, `mpk/run-in-container.sh [-c CONTAINER] [assess.py args...]`
does the same inside a container:

```sh
mpk/run-in-container.sh --mode both --exclude gcc clang
mpk/run-in-container.sh -c my_container sed grep zlib
```

The container is chosen from `-c`, then `$MPK_CONTAINER`, then the running
container that bind-mounts this checkout. If the container mounts the checkout,
the assessment runs on it in place. Otherwise the checkout is synced to
`/home/lind/lind-wasm-apps` in the container and `mpk/results/` is copied back.

### WASM mode

For each app, WASM mode does the following:

1. Runs `make <app>`.
2. Runs `make install-<app>`, the normal workflow. The install stays in
   lindfs, so `lindfs` ends up holding the current WASM builds.
3. Runs the recipe's smoke checks and the app's `run_tests.sh` against the WASM
   programs. The WASM layouts in lindfs match the MPK ones, so the same checks apply.

Builds are cached by stamps in `build/wasm-assess/stamps`. A stamp is keyed on:
- the app's committed tree,
- its `compile_*.sh` scripts,
- the lind-wasm sysroot `libc.a`,
- `LIND_DYLINK`.

When lind-wasm's sysroot changes, the harness first runs
`make rebuild-sysroot rebuild-libs`, so that the merged sysroot and libraries are rebuilt.

Library-only apps have no program to run and are reported as `not-assessed`.
These are zlib, openssl, libtirpc, ed25519 and gnulib. They are exercised
through the apps that link them.

Apps built with `wasm-opt --fpcast-emu` (recipes with
`WASM_RUN_ARGS="--enable-fpcast"`) need a libc/libm built the same way. With
lind-wasm's default runtime they trap `indirect call type mismatch`, for
example when `exit()` runs their atexit handlers. The apps image gets these
libraries from `RUNTIME=fpcast` in [../Dockerfile](../Dockerfile). WASM mode
does not replace the default runtime in lindfs. Instead it:

- builds the fpcast variants from the lind-wasm sysroot into lindfs
  `/lib/fpcast/`, and rebuilds them when the sysroot, lind-boot or
  `lind-wasm-opt` changes;
- runs smoke checks and `run_tests.sh` through a shadow lind-wasm root whose
  `scripts/bin/lind_run` preloads those libraries for these apps.

To run such a program by hand, call lind-boot directly:
`sudo build/lind-boot --preload env=/lib/fpcast/libc.cwasm --preload env=/lib/fpcast/libm.cwasm --enable-fpcast <program>`.

### MPK mode

- Native builds are cached in `build/mpk/native/<app>`. A cached build is reused
  until its recipe, `lib/common.sh` or `bin/lind-mpk-cc` changes, or until you pass `--rebuild`.
- Sources are checked out from the git index (committed plus staged changes).
  The in-tree WASM builds leave objects behind and regenerate tracked files,
  and none of that leaks into the native build. Stage (`git add`) source edits
  that a native build should see.
- Rewrites are cached in `build/mpk/rewrite-cache`. The cache key is the input
  binary, the `gsfork-elf` flags, the rewriter sources and lind's glibc
  (`libc.so.6`, `ld.so`, `libm.so`). Unchanged programs are therefore not
  rewritten again; this matters for openssl, perl, postgres and gcc.
  `--no-rewrite-cache` disables the cache.
- `--mode both` runs WASM first. MPK then backs up the WASM programs it
  replaces in lindfs and restores them at the end.

### Prerequisites (inside the container)

- A lind-wasm checkout in `$LIND_WASM_ROOT` (default `~/lind-wasm`) with:
  - `build/lind-boot` built (`make lind-boot`),
  - the native glibc built at `glibc-2.35/build` and installed at `glibc-2.35/install`,
  - the rewritten loader and libc in `lindfs/lib/elf/` (as needed by
    `lind_compile --mpk`).
- Host build tools from `Docker/Dockerfile.dev` (gcc/g++, autoconf, automake,
  libtool, cmake, bison, flex, rsync), plus `curl` for the nginx check. gcc's
  build downloads GMP, MPFR and MPC once, so it needs network access.
- `lind_run` re-executes itself through `sudo`, so the user needs passwordless sudo,
  as user `lind` has in the dev image.

An MPK run copies programs into `lindfs`. Any files it replaces are backed up to
`build/mpk/lindfs-backup` and restored at the end, unless `--keep-installed` is given.
WASM mode also needs clang for wasm32 (`LLVM_BIN_DIR`). The Makefile finds it
automatically: first the clang bundled with lind-wasm, then the `clang` on `PATH`.

## What is measured

In MPK mode, each app goes through these stages:

| Stage | What happens |
|---|---|
| build | `recipes/<app>.sh: recipe_build` compiles natively with `bin/lind-mpk-cc` / `lind-mpk-c++`. These wrappers mirror `lind_compile --mpk`: `-fPIC -fomit-frame-pointer`, lind glibc headers, `-lc` + `ld.so` from `glibc-2.35/build`, rpath `/lib/elf`, and static libgcc/libstdc++ (`lind_compile` has no C++ path; the C++ wrapper also keeps `ld.so` despite `--as-needed` and pulls `atexit` from `libc_nonshared.a`, which libstdc++.a needs). Programs are staged into a lindfs-shaped tree (`$NATIVE`). Library dependencies (zlib, openssl, libtirpc) are installed statically into `build/mpk/prefix`. |
| rewrite | Every ELF program in the tree is rewritten with exactly the `gsfork-elf rewrite` flags that `lind_compile --mpk` uses. |
| install | Rewritten programs, and data files such as the Perl and Python stdlibs, are copied into lindfs at the paths the wasm builds use. |
| smoke | `recipe_smoke` runs a few representative commands under lind-boot. Each check prints one `SMOKE PASS/FAIL` line; checks of programs that failed to rewrite (and so are not installed) print `SMOKE SKIP`. |
| upstream | The app's own unmodified `<app>/run_tests.sh` runs, the same suite used for the wasm build. Shadow roots in `build/mpk/` point it at the MPK binaries. Recipes set `UPSTREAM_TESTS=0` where the script cannot apply (it needs the wasm build tree or targets i386); the reason is given in the report notes. |

Verdicts:

| Verdict | Meaning |
|---|---|
| compatible | Every program rewrote, and every smoke check and upstream test passed. |
| partial | Runs, but some programs, checks or tests fail. |
| runtime-fail | Rewritten, but no check passes under lind-mpk. |
| rewrite-fail | The native build works, but `gsfork-elf` rejects the program. |
| build-fail | The native build against lind glibc fails. |
| not-assessed | No runnable artifact (gnulib is a source-only library; in WASM mode, library-only builds), skipped by the recipe, every smoke check was skipped (program not installed) with no other check passing, or a harness error. |

`assess.py` extracts lind-boot panics from the logs and groups them by cause,
for example `missing syscall 27 (mincore)` or `panic: Lind unsupported ioctl
request`. Each report's "Blockers by cause" table shows how many apps each runtime
or rewriter gap blocks.

## Recipe format

`recipes/<app>.sh` is sourced by `lib/stage.sh` after `lib/common.sh`:

```sh
KIND=library            # optional (default: app)
DEPS=(zlib openssl)     # built first; their static libs land in $PREFIX
RUNTIME_DEPS=(bash coreutils)  # installed into lindfs before smoke/upstream
UPSTREAM_TESTS=0        # optional: skip <app>/run_tests.sh
NOTE="shown in the report"
SKIP_REASON="..."       # optional: do not assess
# --mode wasm only (all optional):
WASM_RUN_ARGS="--enable-fpcast"   # lind_run flags; --enable-fpcast also selects the fpcast libc/libm
WASM_UPSTREAM_TESTS=0   # skip <app>/run_tests.sh
WASM_SKIP_REASON="..."  # do not assess the wasm build
WASM_NOTE="..."         # shown in the wasm report
WASM_TARGET=gmake       # Makefile target, if it differs from the recipe name
WASM_BUILD_DIR=make     # build/<dir> it stages into, if different

recipe_build() {        # cwd: scratch copy of <app>/
  mpk_configure --disable-nls
  make -j"$JOBS"
  stage_bin src/foo /usr/local/bin/foo
}
recipe_smoke() {        # cwd: $LIND_WASM_ROOT
  printf 'x\n' | fixture /tmp/mpk-foo/in.txt
  smoke version "foo 1." -- /usr/local/bin/foo --version
  smoke fails-cleanly "" --exit 1 -- /usr/local/bin/foo --bad
}
```

The `lib/common.sh` helpers are `mpk_configure`, `autotools_touch`,
`stage_bin`, `fixture`, and `smoke <name> <expected-substring> [--exit N] [--stdin F] -- argv`.
Set `SMOKE_TIMEOUT=<s>` before a `smoke` call to change the per-command timeout.
