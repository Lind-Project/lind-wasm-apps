# CoreUtils Testing on Lind - Findings

## Task Completed

Successfully identified coreutils tests and ran them via lind_run.

## Approach

1. **Built WASM binaries**: `make coreutils` (already completed)
2. **Found test suite**: Located in `coreutils/tests/` directory
3. **Configured for testing**: Ran `./configure` to generate test Makefile
4. **Created wrappers**: Generated wrapper scripts in `src/` calling `lind_run binary.cwasm`
5. **Ran tests**: Executed `make check` with PATH pointing to wrappers

## Test Results

- **PASS**: 1 (rm/dangling-symlink)
- **FAIL**: 16 
- **SKIP**: 6

## Errors Discovered

### Error #1: ioctl Syscall Not Supported

**Affected**: ls and terminal-aware utilities

**Symptom**:
```
thread 'main' panicked at crates/sysdefs/src/logging.rs:6:5:
LIND DEBUG PANIC: Lind unsupported ioctl request
Exit code: 101
```

**Cause**: Programs call ioctl() to query terminal properties

**Impact**: All ls tests fail immediately

### Error #2: Test Infrastructure Sandboxed

**Affected**: Test framework itself (test-lib.sh, make check)

**Symptom**:
```
mktemp.cwasm: failed to create directory ... No such file or directory
cat.cwasm: misc/help-version.log-t: No such file or directory
```

**Cause**: Our wrappers make ALL utilities run in Lind's sandbox, including:
- cat (reads/writes log files)
- rm (cleans up test dirs)
- mktemp (creates temp test dirs)
- chmod (sets test file permissions)

**Impact**: Test framework cannot function - tests fail during setup

### Error #3: Filesystem Access

Lind sandbox doesn't have access to host paths like `/home/lind/lind-wasm-apps/`

## Root Architectural Issue

Need TWO sets of utilities:
1. **Native** for test infrastructure (cat, rm, mkdir, chmod, mktemp)
2. **Lind-wrapped** for the binary being tested

Current approach sandboxes everything, breaking the test framework.

## Files in This PR

- `run_coreutils_tests_lind.sh` - Demonstration script
- `FINDINGS.md` - This analysis document
- Test wrappers (generated at runtime, not committed)

## How Tests Were Run
```bash
cd ~/lind-wasm-apps/coreutils
./configure
# Wrappers created in src/
make -C tests check VERBOSE=yes
```

