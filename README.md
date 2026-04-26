# lind-wasm-apps

Cross-compiled applications for the [Lind](https://github.com/Lind-Project/lind-wasm) secure WebAssembly sandbox. Each app is compiled from source to `wasm32-wasi` using a custom glibc sysroot and runs inside the Lind runtime.

## Prerequisites

- [lind-wasm](https://github.com/Lind-Project/lind-wasm) built and installed (provides the glibc sysroot, LLVM toolchain, wasm-opt, and lind-boot)
- This repo cloned alongside `lind-wasm`:
  ```
  ~/lind-wasm/                    # the runtime
  ~/lind-wasm/lind-wasm-apps/     # this repo
  ```
- Set `LIND_WASM_ROOT` if your layout differs (default: `~/lind-wasm`)

## Quick Start

```bash
# Build the default set (lmbench + bash)
make all

# Install to lindfs
make install

# Run tests
make test
```

## Available Apps

| App | Make target | Description |
|-----|-------------|-------------|
| bash | `make bash` | GNU Bash shell |
| coreutils | `make coreutils` | GNU core utilities (partial, best-effort) |
| curl | `make curl` | HTTP/HTTPS client |
| git | `make git` | Version control |
| grep | `make grep` | Pattern matching |
| sed | `make sed` | Stream editor |
| diffutils | `make diffutils` | cmp, diff, diff3, sdiff |
| awk | `make awk` | GNU awk (gawk) |
| gmake | `make gmake` | GNU make |
| perl | `make perl` | Perl 5 interpreter |
| cpython | `make cpython` | Python 3 interpreter |
| nginx | `make nginx` | HTTP server |
| lmbench | `make lmbench` | Microbenchmark suite |
| tinycc | `make tinycc` | Tiny C Compiler (i386 target) |
| postgres | `make postgres` | PostgreSQL database server |
| gcc | `make gcc` | GCC cc1 compiler (cross-compiled) |
| binutils | `make binutils` | GNU ld + as |
| clang | `make clang` | LLVM/Clang compiler |

## Building

### Build a single app

```bash
make bash          # builds bash
make git           # builds git (auto-builds zlib + openssl first)
make perl          # builds perl (uses perl-cross for cross-compilation)
```

### Build and install

```bash
make bash           # compile
make install-bash   # copy to lindfs
```

Or install everything at once:

```bash
make install        # installs all built apps + shared libraries to lindfs
```

Library dependencies are handled automatically. For example, `make install-git` will run `install-zlib` and `install-openssl` first.

### Dynamic linking (PIE builds)

Set `LIND_DYLINK=1` for position-independent executables that dynamically link shared libraries:

```bash
LIND_DYLINK=1 make git
LIND_DYLINK=1 make install-git    # also installs libz.so, libssl.so, libcrypto.so
```

For static builds (default):

```bash
LIND_DYLINK=0 make git
```

### fpcast-emu (indirect call type mismatch fix)

Some apps (bash, nginx, coreutils, grep) use `--fpcast-emu` in their wasm-opt pass to handle indirect function pointer type mismatches. For dynamic builds, fpcast-emu requires additional setup:

1. Rebuild the lind-wasm sysroot with fpcast support:
   ```bash
   cd ~/lind-wasm
   make sysroot WITH_FPCAST=1
   ```

2. Apps are compiled with `--fpcast-emu` automatically (see each app's compile script)

3. Run with `--enable-fpcast`:
   ```bash
   lind-wasm --enable-fpcast usr/local/bin/bash -c "echo hello"
   ```

Without `WITH_FPCAST=1` in the sysroot, dynamic builds of apps using fpcast-emu will fail with indirect call type mismatch errors at runtime.

## Running

After building and installing, run apps through the Lind runtime:

```bash
# Static builds
lind-wasm usr/local/bin/bash -c "echo hello"
lind-wasm usr/local/bin/git --version

# Apps that use fpcast-emu (bash, nginx, coreutils, grep)
lind-wasm --enable-fpcast usr/local/bin/bash -c "echo hello"

# Dynamic builds (shared libs preloaded automatically after install)
lind-wasm --preload env=lib/libz.so --preload env=lib/libcrypto.so --preload env=lib/libssl.so usr/local/bin/git --version
```

## Testing

```bash
# Run all tests
make test

# Test a single app
APP=bash make test
APP=git make test

# Test multiple apps
APP="bash git grep" make test

# Check that build artifacts exist
make check-build
APP=git make check-build
```

Apps with test suites: bash, coreutils, curl, git, grep, lmbench, sed, tinycc, cpython.

## Build System

### Directory Layout

```
build/
  sysroot_overlay/    # headers + static libs from library builds (zlib, openssl, etc.)
  sysroot_merged/     # base glibc sysroot + overlay combined
  <app>/              # per-app staging dir (installed to lindfs via make install)
  .toolchain.env      # detected toolchain paths (written by make preflight)
```

### Library Targets

These build support libraries into `sysroot_overlay/`, then merge into `sysroot_merged/`:

| Target | Library | Needed by |
|--------|---------|-----------|
| `make libtirpc` | libtirpc | lmbench |
| `make gnulib` | libgnu | sed, grep, curl |
| `make zlib` | libz | git, curl, binutils, cpython |
| `make openssl` | libssl, libcrypto | git, curl, cpython |
| `make libcxx` | libc++, libc++abi | gcc, clang |

Dependencies are resolved automatically. For example, `make git` triggers `make zlib` and `make openssl` if they haven't been built yet.

### Makefile Targets Reference

```bash
make preflight        # detect toolchain, write .toolchain.env
make merge-sysroot    # merge base sysroot + all overlays
make all              # build default set (lmbench + bash)
make <app>            # build a specific app
make install          # install all apps to lindfs
make install-<app>    # install a specific app
make test             # run test suites
make check-build      # verify build artifacts exist
make clean            # clean build artifacts
make rebuild-libs     # force-rebuild library stamps
make rebuild-sysroot  # force-rebuild merged sysroot
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LIND_WASM_ROOT` | `~/lind-wasm` | Path to lind-wasm installation |
| `LIND_DYLINK` | `0` | Set to `1` for dynamic/PIE builds |
| `JOBS` | `$(nproc)` | Parallel build jobs |
| `ARTIFACT_MODE` | `full` | Set to `fast` to skip cwasm generation (dev builds) |
| `FORCE_CLEAN` | `0` | Set to `1` to force full rebuild |

### Compile Script Conventions

Each app has a `<app>/compile_<app>.sh` that follows a standard pattern:

- Sources `.toolchain.env` for `$CLANG`, `$AR`, `$RANLIB`
- Uses `$MERGED_SYSROOT` for headers and libraries
- Runs `wasm-opt` with `--epoch-injection --asyncify -O2`
- Runs `lind-boot --precompile` to generate `.cwasm`
- Stages final binary to `build/<app>/usr/local/bin/<binary>`
- Errors go to stderr with `[app]` prefix

Each app also has a `clean.sh` for removing build artifacts.
