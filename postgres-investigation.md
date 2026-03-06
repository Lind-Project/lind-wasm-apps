# PostgreSQL on Lind-Wasm: Investigation & Fix Guide

## Current Status

PostgreSQL compiles and runs basic commands (`--version`, `--help`) but **cannot initialize or run a database**. Two blockers remain.

## Build Infrastructure

The postgres build lives on the `origin/compile-postgres` branch in the **lind-wasm-apps** repo (`/home/lind/lind-wasm-apps/`). Key files:

- `postgres/compile_postgres.sh` — Two-pass build (native for parser generation, then WASM cross-compile)
- `postgres/wasm_compat.h` — WASI compatibility header
- `postgres/wasi_stubs.c` — Linker stubs for missing WASI functions
- `postgres/config.cache.wasi` — Pre-populated configure cache for cross-compilation

### How to Build

```bash
cd /home/lind/lind-wasm-apps
git checkout compile-postgres
make preflight        # Detect LLVM toolchain
make merge-sysroot    # Prepare merged sysroot
make postgres         # Build postgres (two-pass)
make install-postgres # Install to lindfs/bin/
```

### What Works

```bash
lind_run bin/postgres --version    # "postgres (PostgreSQL) 19devel"
lind_run bin/postgres --help       # Full help text
lind_run bin/initdb --version      # "initdb (PostgreSQL) 19devel"
```

---

## Blocker 1: mmap() Unsupported Flags

### Symptom

```
initdb -D /tmp/pgdata --no-locale
# Panic: "Unsupported mmap flag detected!"
```

### Root Cause

RawPOSIX's `mmap_syscall` only handles a limited set of mmap flags: `MAP_FIXED`, `MAP_SHARED`, `MAP_PRIVATE`, `MAP_POPULATE`, `MAP_ANONYMOUS`. PostgreSQL's `initdb` likely passes `MAP_NORESERVE` or another flag not in this set.

### Investigation Steps

1. **Identify the exact flag causing the panic.** In lind-wasm repo:
   ```bash
   grep -rn "Unsupported mmap flag" src/rawposix/
   ```
   This will show you the mmap flag validation code. Add an `eprintln!` before the panic to print the raw flags value.

2. **Rebuild lind-boot with debug output:**
   ```bash
   cd /home/lind/lind-wasm
   cd src/lind-boot && cargo build --release --features lind_debug
   cp target/release/lind-boot ../../build/lind-boot
   ```

3. **Run initdb again** to see which flag is being passed:
   ```bash
   cd /home/lind/lind-wasm-apps
   sudo lind_run bin/initdb -D /tmp/pgdata --no-locale 2>&1 | tee initdb_debug.log
   ```

4. **Fix:** Add the missing flag(s) to the allowed set in the mmap handler. Common flags postgres might use:
   - `MAP_NORESERVE` (0x4000) — Don't reserve swap space. Safe to accept and ignore in lind-wasm.
   - `MAP_HUGETLB` (0x40000) — Huge pages. Safe to ignore.
   - `MAP_DENYWRITE` (0x0800) — Legacy, safe to ignore.

5. **Key files to modify:**
   - `src/rawposix/src/fs_calls.rs` or wherever `mmap_syscall` is defined
   - Search for the flag validation/panic code and either add the flag to the supported set or mask it out before validation

### Fix Pattern

```rust
// Strip flags that are safe to ignore in lind-wasm
let cleaned_flags = flags & !(MAP_NORESERVE | MAP_HUGETLB | MAP_DENYWRITE);
// Then validate cleaned_flags against supported set
```

---

## Blocker 2: signalfd() Not Implemented

### Symptom

```
postgres --single -D /tmp/pgdata
# FATAL: signalfd() failed
```

### Root Cause

PostgreSQL uses Linux-specific `signalfd()` for its signal handling loop (postmaster process). Lind-wasm's signal subsystem only supports `sigaction`/`sigprocmask`, not `signalfd`.

### Two Approaches

#### Approach A: Patch PostgreSQL (Recommended — Simpler)

PostgreSQL has fallback code for platforms without `signalfd`. Find and enable it:

1. **Search postgres source for signalfd usage:**
   ```bash
   cd /home/lind/lind-wasm-apps/postgres
   grep -rn "signalfd" src/
   ```

2. **Check configure options.** The `config.cache.wasi` file may declare `signalfd` as available:
   ```bash
   grep -i signalfd postgres/config.cache.wasi
   ```
   If `ac_cv_func_signalfd=yes`, change it to `ac_cv_func_signalfd=no`.

3. **Rebuild postgres** after the config change.

4. PostgreSQL should fall back to `sigprocmask` + `sigwaitinfo` or `pselect`-based signal handling.

#### Approach B: Implement signalfd in RawPOSIX (Complex)

Would require:
- New syscall handler for `SYS_signalfd4` (syscall 356 on i386)
- Creating a virtual FD that becomes readable when signals are pending
- Integrating with the existing signal mask/pending infrastructure in `src/cage/`
- Supporting `read()` on the signalfd to dequeue signals as `struct signalfd_siginfo`

This is significant work. **Approach A is recommended** unless other apps also need signalfd.

---

## Blocker 3 (Minor): Execute Permissions

### Symptom

PostgreSQL stats its own binary on startup and may fail if not executable.

### Fix

After `make install-postgres`, run:
```bash
chmod +x /home/lind/lind-wasm-apps/lindfs/bin/*.cwasm
```

Or patch `postgres/compile_postgres.sh` to add `chmod +x` after copying binaries.

---

## Verification Plan

After fixing blockers, test in this order:

1. **initdb succeeds:**
   ```bash
   sudo lind_run bin/initdb -D /tmp/pgdata --no-locale
   ```
   Expected: Creates database cluster in `/tmp/pgdata/` (inside lindfs)

2. **postgres starts in single-user mode:**
   ```bash
   sudo lind_run bin/postgres --single -D /tmp/pgdata postgres
   ```
   Expected: Interactive SQL prompt

3. **Basic SQL works:**
   ```sql
   CREATE TABLE test (id int, name text);
   INSERT INTO test VALUES (1, 'hello');
   SELECT * FROM test;
   ```

## Key File Locations (lind-wasm repo)

- **mmap syscall:** `grep -rn "mmap_syscall\|Unsupported mmap flag" src/rawposix/`
- **Signal handling:** `src/rawposix/src/signal_calls.rs` (or similar)
- **Cage signal state:** `src/cage/src/` (sigset, signal mask)
- **Syscall dispatch:** `src/rawposix/src/lib.rs` or `src/rawposix/src/dispatcher.rs`
- **Build lind-boot:** `cd src/lind-boot && cargo build --release --features lind_debug`

## Priority

1. Fix mmap flags (likely a 10-line change)
2. Patch postgres to disable signalfd (config change + rebuild)
3. Fix chmod (one-liner)
