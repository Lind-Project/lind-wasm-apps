# Handoff: GS-Fork rewrite of gcc (`cc1`) on a large machine

Audience: the agent/person continuing the lind-mpk gcc evaluation on a machine with
much more RAM than the original host. Goal: get `gsfork-elf rewrite` to succeed (or
fail with a concrete, non-resource error) on gcc's `cc1`, then run the gcc smoke tests
under `lind-boot` via the `mpk/` harness.

## 1. Why a bigger machine

- `cc1` (GCC 15.2.0, built by `recipes/gcc.sh`) is ~373 MB with ~27.8 MB `.text`.
- On the original host ddisasm alone reached **85 GB RSS after 44 min, still in its
  first pass** before being killed. The Python/gtirb-rewriting/printer stages afterwards
  are expected to need a comparable amount again.
- Plan for **≥ 200–256 GB RAM** (plus swap as a safety net) and **many hours** of wall time.
  More cores help ddisasm (it uses all CPUs by default).
- The gcc driver (`/usr/local/bin/gcc`) already rewrites fine (~3 min); only `cc1` is the problem.

## 2. Repositories (exact revisions)

| Repo | Remote | Branch | Commit |
|---|---|---|---|
| lind-wasm | `git@github.com:Lind-Project/lind-wasm.git` | `mpk_adv_loading` | `fa5e864f0` |
| lind-wasm-apps | `git@github.com:Lind-Project/lind-wasm-apps.git` | `mpk-sandbox` | tip (contains this file) |
| glibc (custom, PKRU/TCB fields) | `git@github.com:F-Wilke/lind-glibc.git` | `v2.35-manual-interpose` | `d7f7e90a5b` |
| gsfork-prototype (rewriter in `rewriter-v2/`) | `git@github.com:F-Wilke/gsfork-prototype.git` | `master` | `919e6bd` or later |
| lind-wasm-example-grates (optional, mounted by the dev container) | `git@github.com:Lind-Project/lind-wasm-example-grates.git` | `main` | any |

Directory layout (siblings, as the container mounts expect):

```sh
mkdir -p ~/lind && cd ~/lind
git clone -b mpk_adv_loading git@github.com:Lind-Project/lind-wasm.git
git clone -b v2.35-manual-interpose git@github.com:F-Wilke/lind-glibc.git glibc-2.35
git clone git@github.com:F-Wilke/gsfork-prototype.git
git clone git@github.com:Lind-Project/lind-wasm-example-grates.git
cd lind-wasm
ln -s ../glibc-2.35/ glibc-2.35                         # lind_compile/assess expect lind-wasm/glibc-2.35
git clone -b mpk-sandbox git@github.com:Lind-Project/lind-wasm-apps.git   # nested, untracked by lind-wasm
```

On the original host lind-wasm had some uncommitted, unrelated WIP (docs, `.gitignore`,
a grate test). None of it is needed for this evaluation.

## 3. Host requirements and container

- The CPU must support MPK: `grep -m1 -o -w pku /proc/cpuinfo` must print `pku`
  (lind-boot's MPK mode uses PKRU). Intel Xeon Skylake-SP or newer; AMD Zen 3 or newer.
- Docker, passwordless sudo inside the container (the image provides it), and network
  access once (gcc's `contrib/download_prerequisites` fetches GMP/MPFR/MPC).

Build the image and start the container (the commands match `lind-wasm/Docker/README.md`):

```sh
cd ~/lind/lind-wasm
docker build --platform=linux/amd64 --build-arg USERNAME=lind \
    -f Docker/Dockerfile.mnt.dev -t lind-mnt-dev .
docker run -dit --name lind-mpk --platform=linux/amd64 --privileged --ipc=host --init --cap-add=SYS_PTRACE \
    -v "$PWD":/home/lind/lind-wasm \
    -v "$PWD/../lind-wasm-example-grates":/home/lind/lind-wasm-example-grates \
    -v "$PWD/../glibc-2.35":/home/lind/glibc-2.35 \
    -v "$PWD/../gsfork-prototype/rewriter-v2":/home/lind/rewriter \
    lind-mnt-dev bash
docker exec -it -u lind lind-mpk bash
```

lind-wasm-apps is **not** mounted. `mpk/run-in-container.sh` copies the checkout into
the container (`/home/lind/lind-wasm-apps`) and copies `mpk/results` back. Pass
`-c lind-mpk` (or set `MPK_CONTAINER=lind-mpk`), because the script defaults to
`cranky_keldysh`, the container name on the original host.

## 4. One-time setup (inside the container, user `lind`)

Run every step **inside** the container so venv and build paths match.

```sh
# 4a. Rewriter (pinned ddisasm/gtirb wheels; no root needed)
cd ~/rewriter && make install
.venv/bin/python -m unittest discover -s tests   # expect: 72 tests, 3 known errors (the "0x1035" fixtures)
export GSFORK_ELF_BIN=$HOME/rewriter/.venv/bin/gsfork-elf

# 4b. Native custom glibc (adds sandbox_offset/sandbox_scratch to struct pthread)
cd ~/glibc-2.35 && mkdir -p build install && cd build
../configure --prefix=/home/lind/glibc-2.35/install CFLAGS="-O2 -g -fomit-frame-pointer"
make -j"$(nproc)" && make install

# 4c. lind-boot
cd ~/lind-wasm && make lind-boot

# 4d. GS-rewritten loader/libc/libm into lindfs (what lind-boot loads for MPK programs)
cd ~/rewriter && mkdir -p build/glibc
G=../glibc-2.35/build
RW=".venv/bin/gsfork-elf rewrite --scratch-field=sandbox_scratch --sandbox-field=sandbox_offset --tcb-layout $G/libc.so"
$RW $G/elf/ld.so      build/glibc/ld.gs   -L $G/elf
$RW $G/libc.so        build/glibc/libc.gs -L $G/elf -L $G --trust-library ld-linux-x86-64.so.2
$RW $G/math/libm.so   build/glibc/libm.gs -L $G/elf -L $G --trust-library ld-linux-x86-64.so.2 --trust-library libc.so.6
L=~/lind-wasm/lindfs/lib
mkdir -p $L/elf
cp build/glibc/ld.gs $L/   && ln -sf ld.gs   $L/ld-linux-x86-64.so.2
cp build/glibc/libc.gs $L/elf/ && ln -sf libc.gs $L/elf/libc.so.6
cp build/glibc/libm.gs $L/elf/ && ln -sf libm.gs $L/elf/libm.so.6
```

Expected layout: `lindfs/lib/ld.gs`, `lindfs/lib/ld-linux-x86-64.so.2 -> ld.gs`, and
`lindfs/lib/elf/{libc.gs,libc.so.6,libm.gs,libm.so.6}`. lind-boot hard-codes
`/lib/ld-linux-x86-64.so.2` and `/lib/elf` (`src/lind-boot/src/lind_mpk/execute.rs`).
To sanity-check the chain, run a small app first, e.g. `mpk/run-in-container.sh -c lind-mpk zlib`.

## 5. Running the gcc evaluation

### Option A: through the harness (preferred; produces the report entry)

From the host, in `lind-wasm-apps`:

```sh
mpk/run-in-container.sh -c lind-mpk gcc --rewrite-timeout 172800
```

- `--rewrite-timeout` (seconds, default 3600) is both the harness timeout per binary
  and `GSFORK_TOOL_TIMEOUT` for each ddisasm/printer run. 3600 is far too small for `cc1`.
- The harness rewrites up to `--rewrite-workers` (default 8) binaries in parallel.
  gcc only has two (driver and `cc1`), so that is fine.
- The native build is cached in `build/mpk/native/gcc` (inside the container's copy).
  `--rebuild` forces a rebuild.
- Results merge into `mpk/results/report.{md,json}`; logs are in `mpk/results/logs/gcc/`.
  Failure diagnostics (`*.failed-*` dirs with `recovery.log`, `baseline.S`, and so on) go to
  `build/mpk/rewrite-artifacts/gcc/` inside the container.
- `run-in-container.sh` uses `docker exec` in the foreground. Run it under `tmux`/`nohup`,
  because the run takes many hours.

### Option B: rewrite `cc1` directly (better for profiling/iterating)

After one harness run has built gcc (or inside the container after a build):

```sh
N=~/lind-wasm-apps/build/mpk/native/gcc
G=~/lind-wasm/glibc-2.35/build
export GSFORK_TOOL_TIMEOUT=172800          # per ddisasm/printer subprocess
# export GSFORK_DDISASM_THREADS=$(nproc)   # default already = all CPUs
# export GSFORK_TOOL_MEMORY=230000         # optional: kill ddisasm/printer above this many MiB
/usr/bin/time -v $GSFORK_ELF_BIN rewrite \
    $N/usr/local/libexec/gcc/x86_64-pc-linux-gnu/15.2.0/cc1 /tmp/cc1.gs \
    --scratch-field=sandbox_scratch --sandbox-field=sandbox_offset \
    -L $G/elf -L $G --tcb-layout $G/libc.so.6 \
    --trust-library ld-linux-x86-64.so.2 --trust-library libm.so.6 --trust-library libc.so.6 \
    2>&1 | tee /tmp/cc1.rewrite.log
```

This is the exact command the harness uses (`assess.py: rewrite_one`).
`/usr/bin/time -v` reports peak RSS only for the Python process. Watch ddisasm separately:
`ps -o pid,rss,etime,args -C ddisasm`, or sample `/proc/<pid>/status` (`VmHWM`).
A rewritten output can't be run directly (it segfaults without GS set up). It has to run
through lind-boot, which is what the harness smoke step does.

## 6. What to report back

1. Machine: CPU model and cores, RAM, swap, kernel; and whether `pku` is present.
2. For `cc1`: success or failure; total wall time; approximate time per stage; peak RSS of
   ddisasm and of the Python process. gsfork-elf does not log stage timings. Note when
   `ddisasm` exits and when `gtirb-pprinter`/`as`/`ld` start, e.g. with a `ps` loop that
   logs timestamps to a file.
3. If it fails: the last ~50 lines of the rewrite log, plus the `*.failed-*` directory.
4. If the rewrite succeeds: the smoke results (`gcc -v`, `-E`, `-S`, `-c`, 180 s timeout each)
   from `mpk/results/report.md`, and the logs in `mpk/results/logs/gcc/`.

## 7. Known state and caveats

- Rewriter (`919e6bd`) fixes all errors from the previous report: GOT RELATIVE slots,
  renamed/quoted symbols, cyclic/self symbol forwarding, NOTRACK memory branches,
  27 new mnemonics, raw-byte fallbacks (`sha1msg2`, ...), LSDA exception-spec
  filters/type tables, and CFI expressions. Verified: python, gcc driver, bash, readelf,
  and curl rewrite successfully.
- `mpk/results/report.md` in this branch **predates** those fixes. For example, it still shows
  the gcc driver failing with "cyclic GTIRB symbol forwarding", so don't treat it as current.
- Failures that remain and are not rewriter failures: coreutils needs an extra shared library;
  some syscalls/ioctls are missing from the lind MPK runtime.
- Rewriter tuning knobs (see the "Rewriter scaling" section of `rewriter-v2/README.md`):
  `GSFORK_TOOL_TIMEOUT`, `GSFORK_DDISASM_THREADS`, and `GSFORK_TOOL_MEMORY`. Child tools
  are killed when gsfork-elf dies (`PR_SET_PDEATHSIG`). The harness kills the whole process
  group on timeout.
