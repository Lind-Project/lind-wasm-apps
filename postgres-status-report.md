# PostgreSQL on Lind-Wasm: Status Report (2026-03-06)

## Summary

PostgreSQL 19devel compiles to WASM and runs basic commands. Two of the three original blockers are fixed. A new deeper blocker was discovered: glibc's `popen()` uses `posix_spawn()` which is not implemented, preventing `initdb` from bootstrapping a database.

---

## What Works Now

```bash
# All via lind-boot (not lind_run — see "Runtime" section below)
sudo /home/lind/lind-wasm/build/lind-boot /bin/postgres.wasm --version
# → postgres (PostgreSQL) 19devel

sudo /home/lind/lind-wasm/build/lind-boot /bin/initdb.wasm --version
# → initdb (PostgreSQL) 19devel

sudo /home/lind/lind-wasm/build/lind-boot /bin/postgres.wasm --single -D /tmp/pgdata
# → "could not access postgresql.conf" (needs initdb first, but no crash!)

# fork+execv works (proven with test):
fork + execv("/bin/postgres.wasm", {"postgres.wasm", "--version", NULL})  # ✅
fork + execv("/bin/bash", {"sh", "-c", "/bin/postgres.wasm --version", NULL})  # ✅
```

---

## Fixes Applied

### Fix 1: mmap flags (lind-wasm repo — committed to working tree, not pushed)

**Problem:** RawPOSIX panicked on `MAP_STACK` (0x20000) and `MAP_NORESERVE` (0x4000) flags. PostgreSQL's initdb triggered both.

**Files changed:**

- `src/sysdefs/src/constants/fs_const.rs` — Added constants:
  ```rust
  pub const MAP_NORESERVE: u32 = 0x4000;
  pub const MAP_STACK: u32 = 0x20000;
  pub const MAP_DENYWRITE: u32 = 0x0800;
  ```

- `src/rawposix/src/fs_calls.rs` — Added to import list and allowed flags bitmask:
  ```rust
  let allowed_flags = MAP_FIXED as i32
      | MAP_SHARED as i32
      | MAP_PRIVATE as i32
      | MAP_ANONYMOUS as i32
      | MAP_POPULATE as i32
      | MAP_NORESERVE as i32
      | MAP_STACK as i32
      | MAP_DENYWRITE as i32;
  ```
  Also added `eprintln!` before the panic to print unknown flags for future debugging:
  ```rust
  eprintln!("mmap flags=0x{:x}, unknown=0x{:x}", flags, flags & !allowed_flags);
  ```

**Note:** All three flags are hint/legacy flags that are safe to accept and ignore. `MAP_NORESERVE` = don't reserve swap, `MAP_STACK` = hint for stack usage, `MAP_DENYWRITE` = legacy no-op since Linux 2.6.

### Fix 2: signalfd disabled (lind-wasm-apps repo)

**Problem:** PostgreSQL used Linux-specific `signalfd()` for its event loop, which isn't implemented in lind-wasm.

**Files changed:**

- `postgres/compile_postgres.sh` — Added to config cache template (lines ~267-269):
  ```bash
  ac_cv_header_sys_signalfd_h=${ac_cv_header_sys_signalfd_h=no}
  ac_cv_func_signalfd=${ac_cv_func_signalfd=no}
  ```

- `postgres/config.cache.wasi` — Changed:
  ```
  ac_cv_header_sys_signalfd_h=${ac_cv_header_sys_signalfd_h=no}
  ```
  (was `=yes`)

**Result:** `pg_config.h` now has `/* #undef HAVE_SYS_SIGNALFD_H */`. PostgreSQL falls back to `WAIT_USE_SELF_PIPE` (self-pipe for signal wakeups with epoll), which works.

### Fix 3: find_other_exec version check (lind-wasm-apps repo)

**Problem:** `initdb` calls `find_other_exec()` which runs `popen("postgres -V")` to verify the postgres binary version. `popen` segfaults (see blocker below).

**File changed:**

- `postgres/src/common/exec.c` — Added `#ifdef __wasi__` block in `find_other_exec()` to skip the `pipe_read_line` version check:
  ```c
  if (validate_exec(retpath) != 0)
      return -1;

  #ifdef __wasi__
  (void) versionstr;
  return 0;
  #else
  // ... original pipe_read_line version check ...
  #endif
  ```

### Fix 4: Runtime prerequisites (lindfs setup)

Created necessary directories and files in the chroot:
```bash
sudo mkdir -p /home/lind/lind-wasm/lindfs/lib/postgresql
sudo mkdir -p /home/lind/lind-wasm/lindfs/tmp
sudo ln -sf bash /home/lind/lind-wasm/lindfs/bin/sh
sudo chmod +x /home/lind/lind-wasm/lindfs/bin/*.wasm
```

---

## Remaining Blocker: `popen()` / `posix_spawn()`

### The Problem

`initdb` uses `popen()` extensively — not just for the version check, but for its **entire bootstrap loop**. Every catalog-creation SQL command is sent to postgres via:
```c
#define PG_CMD_OPEN(cmd) \
    cmdfd = popen_check(cmd, "w");  // runs "postgres --boot ..." via shell
```

glibc's `popen()` implementation (`libio/iopopen.c`) uses `__posix_spawn()` internally (NOT `fork+exec`):
```c
// glibc/libio/iopopen.c line 89
err = __posix_spawn(&pid, _PATH_BSHELL, fa, 0,
    (char *const[]){ "sh", "-c", "--", command, NULL }, __environ);
```

`posix_spawn` is not implemented in lind-wasm's RawPOSIX, causing a segfault.

### Key Evidence

| Test | Result |
|------|--------|
| `fork + execv("/bin/bash", {"sh", "-c", "cmd"})` | ✅ Works |
| `fork + execv("/bin/postgres.wasm", {"postgres.wasm", "--version"})` | ✅ Works |
| `popen("echo hello", "r")` | ❌ Segfault |
| `popen("/bin/postgres.wasm --version", "r")` | ❌ Segfault |

### Three Fix Options

#### Option A: Patch glibc's `popen` to use `fork+exec` (Recommended)

Replace `posix_spawn` with `fork+execv` in `src/glibc/libio/iopopen.c`. This is a single-file change that fixes `popen` for all apps. The `posix_spawn` optimization (avoids full address-space copy) isn't relevant in lind-wasm's single-address-space WASM model.

Sketch:
```c
// In spawn_process(), replace __posix_spawn with:
pid_t child = fork();
if (child == 0) {
    // child: dup2 pipe fd, close others, exec /bin/sh
    dup2(pipe_fds[child_end], child_pipe_fd);
    close(pipe_fds[parent_end]);
    execv(_PATH_BSHELL, (char *const[]){"sh", "-c", "--", command, NULL});
    _exit(127);
}
((_IO_proc_file *) fp)->pid = child;
```

After patching, rebuild glibc sysroot (`make sysroot` in lind-wasm) and rebuild postgres.

#### Option B: Implement `posix_spawn` in RawPOSIX

Would need:
- New syscall handler that creates a child process with the specified file actions
- Pipe fd manipulation (dup2) in the child before exec
- Integration with existing fork/exec infrastructure

More correct but significantly more work.

#### Option C: Patch initdb to use `fork+exec+pipe` instead of `popen`

Replace the `PG_CMD_OPEN` macro and `popen_check` in `src/bin/initdb/initdb.c` with a custom implementation using `fork+execv+pipe+dup2`. This avoids touching glibc but is postgres-specific and the patch would be larger.

---

## Runtime Notes

### lind-boot vs lind_run

- **`lind_run`** uses `build/wasmtime` (falls through to `src/wasmtime/target/release/wasmtime`) — an older binary from Feb 13 that does NOT have `lind_debug` support
- **`lind-boot`** (`build/lind-boot`) is the correct runtime — built with `--release --features lind_debug`
- The glibc sysroot bakes `debug::lind_debug_num` and `debug::lind_debug_str` imports into ALL wasm binaries, so `lind_debug` feature is **required** at runtime
- Must use `sudo` for chroot
- Paths are relative to the chroot root (e.g., `/bin/postgres.wasm` not `lindfs/bin/postgres.wasm`)

### Building lind-boot

```bash
cd /home/lind/lind-wasm
cargo build --manifest-path src/lind-boot/Cargo.toml --release --features lind_debug
cp src/lind-boot/target/release/lind-boot build/lind-boot
```

### Rebuilding postgres

```bash
cd /home/lind/lind-wasm-apps
bash postgres/compile_postgres.sh
# Then install:
cp build/bin/postgres/wasm32-wasi/postgres.opt.wasm /home/lind/lind-wasm/lindfs/bin/postgres.wasm
cp build/bin/postgres/wasm32-wasi/initdb.opt.wasm /home/lind/lind-wasm/lindfs/bin/initdb.wasm
chmod +x /home/lind/lind-wasm/lindfs/bin/*.wasm
```

---

## Compile Script Assessment

The compile script (`postgres/compile_postgres.sh`) is well-structured. It does a two-pass build (native for parser generation, WASM for cross-compile) and handles many edge cases. Specific observations:

**Good:**
- Proper two-pass strategy preserving generated flex/bison sources
- Disables shared libraries correctly (wasm-ld limitation)
- Patches `pg_config.h` for WASI (EXEC_BACKEND, semaphores, spinlocks)
- Patches root-user check
- wasm-opt with asyncify + epoch injection
- Best-effort build continues on non-fatal errors

**Missing (now fixed):**
- ~~signalfd not disabled~~ → Fixed in config cache
- ~~No source-level patches for popen/posix_spawn~~ → Partially fixed (find_other_exec)

**Potential issues for later:**
- `--disable-thread-safety` may conflict with lind-wasm's pthread support
- SysV shared memory (`pgac_cv_ipc_shmem_kind=sysv`) might not work correctly
- No `--with-pgport` specified — defaults to 5432

---

## Verification Plan (Once popen is fixed)

```bash
# 1. Initialize database
sudo /home/lind/lind-wasm/build/lind-boot /bin/initdb.wasm -D /tmp/pgdata --no-locale

# 2. Start postgres single-user
sudo /home/lind/lind-wasm/build/lind-boot /bin/postgres.wasm --single -D /tmp/pgdata postgres

# 3. Run SQL
CREATE TABLE test (id int, name text);
INSERT INTO test VALUES (1, 'hello');
SELECT * FROM test;
```

---

## File Inventory

### lind-wasm repo (modified, not committed)
- `src/sysdefs/src/constants/fs_const.rs` — MAP_NORESERVE, MAP_STACK, MAP_DENYWRITE constants
- `src/rawposix/src/fs_calls.rs` — mmap allowed flags + debug print

### lind-wasm-apps repo (modified, not committed)
- `postgres/compile_postgres.sh` — signalfd config cache entries
- `postgres/config.cache.wasi` — signalfd header disabled
- `postgres/src/common/exec.c` — find_other_exec WASI skip

### Test file created
- `tests/unit-tests/process_tests/deterministic/test_popen.c` — popen/fork+exec test (can be deleted)
