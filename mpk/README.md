# lind-mpk compatibility assessment

This directory measures which lind-wasm-apps already run under lind-wasm's
native **MPK backend** (`lind_compile --mpk`: x86-64 ELF programs linked
against lind's glibc, rewritten by `gsfork-elf`, and run by `lind-boot` with
PKRU-based isolation instead of WebAssembly).

The latest results are in [results/report.md](results/report.md). Machine-readable
data is in `results/report.json`, and logs are in `results/logs/<app>/`.

To set up a fresh machine from scratch (repos, container, glibc, lind-boot, rewriter)
and run the large gcc `cc1` rewrite, see [GCC-EVAL-HANDOFF.md](GCC-EVAL-HANDOFF.md).

## Reproducing

To use a lind dev container that does **not** mount this repo, run this from the host:

```sh
mpk/run-in-container.sh                       # all apps (~8 hours; large rewrites such as openssl/perl/gcc dominate)
mpk/run-in-container.sh sed grep zlib         # only some apps (merged into the existing report)
mpk/run-in-container.sh -c my_container --rebuild coreutils
```

The script syncs the checkout to `/home/lind/lind-wasm-apps` in the container
(default container: `$MPK_CONTAINER`, or `cranky_keldysh`), runs the
assessment as user `lind`, and copies `mpk/results/` back.

If the container already mounts this repo, for example
`docker run -v $PWD:/home/lind/lind-wasm-apps ...`, run the assessment inside it:

```sh
python3 mpk/assess.py [apps...] [--rebuild] [--keep-installed] [--no-upstream]
```

`python3 mpk/assess.py --help` lists the timeouts, the work directory
(`build/mpk`) and the other options. Native builds are cached in
`build/mpk/native/<app>`. A cached build is reused until its recipe,
`lib/common.sh` or `bin/lind-mpk-cc` changes, or until you pass `--rebuild`.

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

The run copies programs into `lindfs`. Any files it replaces are backed up to
`build/mpk/lindfs-backup` and restored at the end, unless `--keep-installed` is given.

## What is measured

Each app goes through these stages:

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
| not-assessed | No runnable artifact (gnulib is a source-only library). |

`assess.py` extracts lind-boot panics from the logs and groups them by cause,
for example `missing syscall 27 (mincore)` or `panic: Lind unsupported ioctl
request`. The report's "Blockers by cause" table shows how many apps each runtime
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
