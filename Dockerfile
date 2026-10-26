# syntax=docker/dockerfile:1.7-labs

# Build and test lind-wasm-apps on top of the lind-wasm release image.
#
# Stages:
#   build     - preflight + merge-sysroot (fail-fast), build all apps
#               (continue-and-record), create the lindfs layout, install
#               into /lindfs, select the runtime libraries (fpcast or
#               default), create device nodes, keep LIND_WASM_ROOT under sudo
#   test      - run app tests, one `make test APP=<app>` per app
#               (continue-and-record)
#   artifacts - build and test results (results.tsv, test-results.tsv,
#               env.txt, per-target logs), for export
#
# App build and test failures do NOT fail `docker build`. Check results.tsv
# and test-results.tsv instead.
#
# Usage (from lind-wasm-apps repo root):
#   # 1) build image (no tests)
#   docker build --platform=linux/amd64 \
#     --build-arg APPS_COMMIT=$(git rev-parse HEAD) \
#     --target build -t lind-wasm-apps:build-local .
#
#   # 2) run tests and export build + test results (reuses the build cache)
#   docker build --platform=linux/amd64 \
#     --build-arg APPS_COMMIT=$(git rev-parse HEAD) \
#     --target artifacts --output type=local,dest=./apps-results .
#
#   # build / test a subset only (quick local iteration)
#   docker build ... --build-arg APPS="sed grep" --build-arg TEST_APPS="sed grep" ...
#
#   # use the default (non-fpcast) runtime libraries instead
#   docker build ... --build-arg RUNTIME=default ...
#
# NOTE: BuildKit caches the test step like any other step. If nothing changed,
# a rebuild reuses the previous test results without running the tests again.
# To force a new test run locally, add: --no-cache-filter test

# Base image: lind-wasm release image (toolchain, sysroot, lind_debug.o, lindfs,
# and the fpcast runtime libraries in /prebuilt-lindfs-fpcast/lib).
# TODO: switch to securesystemslab/lind-wasm:latest once the lind-wasm PR that
# adds /prebuilt-lindfs-fpcast/lib is merged and the image is published.
# Until then this is a locally built image (Docker/Dockerfile.e2e --target release
# from that PR branch); it cannot be pulled from Docker Hub.
# Use --pull in CI so the latest published release image is always used.
ARG BASE_IMAGE=lind-wasm:release-fpcast-pr


FROM ${BASE_IMAGE} AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Apps to build. clang is excluded: compile_clang.sh fails with
# "LD: unbound variable", and clang has no tests yet.
ARG APPS="lmbench bash nginx coreutils git curl grep sed binutils diffutils perl awk gmake tinycc cpython postgres gcc"
# Libraries to install into lindfs (ed25519 is header-only, no install target).
# NOTE: build ARGs are exported as environment variables to every RUN below.
# Do not use names that autoconf/make read from the environment (CC, CFLAGS,
# LDFLAGS, LIBS, ...): e.g. an ARG named LIBS was appended to every configure
# link test and broke the libtirpc build.
ARG INSTALL_LIBS="libtirpc gnulib zlib openssl libcxx"
# Commit of lind-wasm-apps being built (.git is excluded from the build context).
ARG APPS_COMMIT=unknown

ENV RESULTS_DIR=/apps-results

WORKDIR /apps
COPY . /apps

# Record build context for traceability.
RUN mkdir -p "$RESULTS_DIR/logs" \
 && { echo "date: $(date -Is)"; \
      echo "apps_commit: ${APPS_COMMIT}"; \
      echo "nproc: $(nproc)"; \
      make -C /apps print-config; } > "$RESULTS_DIR/env.txt" 2>&1 \
 && printf "target\texit\tseconds\n" > "$RESULTS_DIR/results.tsv" \
 && cat "$RESULTS_DIR/env.txt"

# Step 1: build environment. Fail-fast: nothing after this is meaningful if it fails.
# merge-sysroot also builds libtirpc, gnulib, zlib, openssl, libc++ and merges ed25519.
RUN make -C /apps preflight     2>&1 | tee "$RESULTS_DIR/logs/preflight.log" \
 && make -C /apps merge-sysroot 2>&1 | tee "$RESULTS_DIR/logs/merge-sysroot.log"

# Step 2: build apps. Continue-and-record: one make call per app, so the
# Makefile's fail-fast shell flags stop only that app. Top-level make stays
# serial; each compile script already uses JOBS=$(nproc) internally.
RUN <<'EOF'
#!/usr/bin/env bash
set -uo pipefail   # no -e: record failures and keep going
for t in $APPS; do
  start=$(date +%s)
  make -C /apps "$t" > "$RESULTS_DIR/logs/$t.log" 2>&1
  rc=$?
  printf "%s\t%s\t%s\n" "$t" "$rc" "$(( $(date +%s) - start ))" >> "$RESULTS_DIR/results.tsv"
  if [ "$rc" -eq 0 ]; then
    echo "[OK]   $t"
  else
    echo "[FAIL] $t (exit $rc) -- last 20 lines:"
    tail -n 20 "$RESULTS_DIR/logs/$t.log"
  fi
done
EOF

# Step 3: lindfs directory layout and config files, as lind-wasm's `make lindfs`
# creates them. The release image ships only /lindfs/lib, but app tests use
# /tmp, /etc/passwd (nginx), locale data, ... inside the sandbox.
# Mirrors the 'lindfs' target in lind-wasm's Makefile, except `touch dev/null`:
# device nodes are created in Step 6. Keep in sync with that target.
# Runs before install, like a local `make lindfs` followed by `make install-<app>`.
RUN for d in bin dev etc grates lib sbin tmp usr/bin usr/lib usr/lib/locale \
             usr/local/bin usr/share/zoneinfo var var/log var/run; do \
      mkdir -p "/lindfs/$d"; \
    done \
 && cp -rT /scripts/config/lindfs-conf/etc                /lindfs/etc \
 && cp -rT /scripts/config/lindfs-conf/usr/lib/locale     /lindfs/usr/lib/locale \
 && cp -rT /scripts/config/lindfs-conf/usr/share/zoneinfo /lindfs/usr/share/zoneinfo \
 && if [ -d /usr/share/zoneinfo ]; then \
      cp -r /usr/share/zoneinfo/* /lindfs/usr/share/zoneinfo/; \
    fi \
 && ls /lindfs /lindfs/etc

# Step 4: install into /lindfs. Libraries first, then only the apps that built.
# The aggregate 'install' target is not used: install-* targets do not depend
# on their builds, so one unbuilt app would abort the whole install.
RUN <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
run_install() {
  local t="install-$1" start rc
  start=$(date +%s)
  make -C /apps "$t" > "$RESULTS_DIR/logs/$t.log" 2>&1
  rc=$?
  printf "%s\t%s\t%s\n" "$t" "$rc" "$(( $(date +%s) - start ))" >> "$RESULTS_DIR/results.tsv"
  echo "[$( [ "$rc" -eq 0 ] && echo OK || echo FAIL )] $t"
}
for lib in $INSTALL_LIBS; do run_install "$lib"; done
for app in $APPS; do
  if awk -v t="$app" '$1==t && $2==0 {f=1} END {exit !f}' "$RESULTS_DIR/results.tsv"; then
    run_install "$app"
  else
    printf "%s\t%s\t%s\n" "install-$app" "skipped" "0" >> "$RESULTS_DIR/results.tsv"
    echo "[SKIP] install-$app (build failed)"
  fi
done
# Print the summary with cat: `column` is not installed in the base image, and
# this is the last command, so its exit code becomes the RUN's exit code.
echo; cat "$RESULTS_DIR/results.tsv"
EOF

# Step 5: select the runtime libraries (libc/libm .so and .cwasm) in /lindfs/lib.
#   fpcast  - copy the fpcast build from the release image over the default one.
#             Required by apps built with `wasm-opt --fpcast-emu`; matches the
#             environment the apps tests were developed against.
#   default - keep the release image's default runtime libraries.
# Runs after install so it cannot be overwritten by install steps. Only libc/libm
# are replaced; libraries installed by the apps (zlib, openssl, ...) are kept.
# ARG is declared here so changing it reuses the cached build/install layers.
ARG RUNTIME=fpcast
RUN case "$RUNTIME" in \
      fpcast) \
        test -d /prebuilt-lindfs-fpcast/lib \
          || { echo "ERROR: /prebuilt-lindfs-fpcast/lib missing in base image; use a lind-wasm release image with fpcast runtime libraries, or RUNTIME=default"; exit 1; } \
        && cp -a /prebuilt-lindfs-fpcast/lib/. /lindfs/lib/ ;; \
      default) ;; \
      *) echo "ERROR: unknown RUNTIME '$RUNTIME' (expected: fpcast | default)"; exit 1 ;; \
    esac \
 && { echo "runtime: ${RUNTIME}"; \
      cd /lindfs/lib && sha256sum libc.so libc.cwasm libm.so libm.cwasm; } >> "$RESULTS_DIR/env.txt" \
 && tail -n 5 "$RESULTS_DIR/env.txt"

# Step 6: device nodes needed at runtime (curl TLS needs /dev/urandom).
# Checks for a character device (-c), not just a path (-e), so a placeholder
# file (e.g. from `touch dev/null` in `make lindfs`) is replaced by a real node.
RUN mkdir -p /lindfs/dev \
 && { [ -c /lindfs/dev/null ]    || { rm -f /lindfs/dev/null;    mknod -m 666 /lindfs/dev/null    c 1 3; }; } \
 && { [ -c /lindfs/dev/random ]  || { rm -f /lindfs/dev/random;  mknod -m 666 /lindfs/dev/random  c 1 8; }; } \
 && { [ -c /lindfs/dev/urandom ] || { rm -f /lindfs/dev/urandom; mknod -m 666 /lindfs/dev/urandom c 1 9; }; } \
 && ls -l /lindfs/dev

# Step 7: keep LIND_WASM_ROOT when tests call `sudo lind_run` (e.g. grep).
# sudo resets the environment, and without LIND_WASM_ROOT lind_run cannot find
# the repo root in the release image (no /Makefile, no git), so it exits with
# "Could not locate lind-wasm repo root" before the app runs.
RUN echo 'Defaults env_keep += "LIND_WASM_ROOT"' > /etc/sudoers.d/lind-wasm-root \
 && chmod 0440 /etc/sudoers.d/lind-wasm-root \
 && visudo -cf /etc/sudoers.d/lind-wasm-root


# Run the app tests. Each app runs in its own `make test APP=<app>` call,
# because the Makefile 'test' loop stops at the first failing app (fail-fast
# shell flags). How an app is tested (run_tests.sh) is owned by the Makefile;
# this stage only picks the apps, runs them one by one and records results.
FROM build AS test

# Apps to test. Default: the apps built with `wasm-opt --fpcast-emu` that have
# standardized tests ('make' is the test name for the gmake build target).
# Not included: apps that do not need fpcast (curl, sed, tinycc, git, ...),
# lmbench (benchmark, not pass/fail) and postgres (no tests yet).
# Override for local runs, e.g. --build-arg TEST_APPS="sed curl".
# Named TEST_APPS, not TESTS: automake reads TESTS (see the LIBS note).
ARG TEST_APPS="awk bash coreutils grep make nginx perl"

# Continue-and-record: a failing app does not stop the others or the build.
# Apps whose build or install did not succeed are recorded as "skipped".
RUN <<'EOF'
#!/usr/bin/env bash
set -uo pipefail   # no -e: record failures and keep going
TEST_RESULTS="$RESULTS_DIR/test-results.tsv"
printf "app\texit\tseconds\n" > "$TEST_RESULTS"
echo "test_apps: ${TEST_APPS}" >> "$RESULTS_DIR/env.txt"
# Record the environment the tests run in (HOME, PATH, user, ...): it differs
# between `docker build`, `docker run` and a developer's shell.
{ id; env | sort; } > "$RESULTS_DIR/test-env.txt"
for app in $TEST_APPS; do
  # Test name -> build target name (GNU make is built as 'gmake').
  case "$app" in
    make) target=gmake ;;
    *)    target="$app" ;;
  esac
  # Install only runs for apps that built, so a successful install means both.
  if ! awk -v t="install-$target" '$1==t && $2==0 {f=1} END {exit !f}' "$RESULTS_DIR/results.tsv"; then
    printf "%s\t%s\t%s\n" "$app" "skipped" "0" >> "$TEST_RESULTS"
    echo "[SKIP] $app (not built or not installed)"
    continue
  fi
  start=$(date +%s)
  make -C /apps test APP="$app" > "$RESULTS_DIR/logs/test-$app.log" 2>&1
  rc=$?
  printf "%s\t%s\t%s\n" "$app" "$rc" "$(( $(date +%s) - start ))" >> "$TEST_RESULTS"
  echo "[$( [ "$rc" -eq 0 ] && echo PASS || echo FAIL )] $app (exit $rc) -- last 5 lines:"
  tail -n 5 "$RESULTS_DIR/logs/test-$app.log"
done
# Last command decides the RUN's exit code; keep it one that always succeeds.
echo; cat "$TEST_RESULTS"
EOF


# Export build and test results: results.tsv, test-results.tsv, env.txt, logs/
#   docker build --target artifacts --output type=local,dest=<dir> .
# This runs the test stage. For build results only, use --target build and read
# /apps-results from the image.
FROM scratch AS artifacts
COPY --from=test /apps-results /
