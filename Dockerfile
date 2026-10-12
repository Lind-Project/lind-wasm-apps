# syntax=docker/dockerfile:1.7-labs

# Build (and later test) all lind-wasm-apps on top of the lind-wasm release image.
#
# Stages:
#   build     - preflight + merge-sysroot (fail-fast), build all apps
#               (continue-and-record), install into /lindfs, create device nodes
#   test      - (TODO) run app tests; to be added once test scripts are ready
#   artifacts - build results only (results.tsv + per-target logs), for export
#
# App build failures do NOT fail `docker build`. Check results.tsv instead.
#
# Usage (from lind-wasm-apps repo root):
#   # 1) build image
#   docker build --platform=linux/amd64 -f Docker/Dockerfile.apps \
#     --build-arg APPS_COMMIT=$(git rev-parse HEAD) \
#     --target build -t lind-wasm-apps:build-local .
#
#   # 2) export build results (reuses the cache from step 1)
#   docker build --platform=linux/amd64 -f Docker/Dockerfile.apps \
#     --build-arg APPS_COMMIT=$(git rev-parse HEAD) \
#     --target artifacts --output type=local,dest=./apps-build-results .
#
#   # build a subset only (quick local iteration)
#   docker build ... --build-arg APPS="sed grep" ...

# Base image: lind-wasm release image (toolchain, sysroot, lind_debug.o, lindfs).
# Use --pull in CI so the latest published release image is always used.
ARG BASE_IMAGE=securesystemslab/lind-wasm:latest


FROM ${BASE_IMAGE} AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Apps to build. clang is excluded: compile_clang.sh fails with
# "LD: unbound variable", and clang has no tests yet.
ARG APPS="lmbench bash nginx coreutils git curl grep sed binutils diffutils perl awk gmake tinycc cpython postgres gcc"
# Libraries to install into lindfs (ed25519 is header-only, no install target).
ARG LIBS="libtirpc gnulib zlib openssl libcxx"
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

# Step 3: install into /lindfs. Libraries first, then only the apps that built.
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
for lib in $LIBS; do run_install "$lib"; done
for app in $APPS; do
  if awk -v t="$app" '$1==t && $2==0 {f=1} END {exit !f}' "$RESULTS_DIR/results.tsv"; then
    run_install "$app"
  else
    printf "%s\t%s\t%s\n" "install-$app" "skipped" "0" >> "$RESULTS_DIR/results.tsv"
    echo "[SKIP] install-$app (build failed)"
  fi
done
echo; column -t "$RESULTS_DIR/results.tsv"
EOF

# Step 4: device nodes needed at runtime (curl TLS needs /dev/urandom).
RUN mkdir -p /lindfs/dev \
 && { [ -e /lindfs/dev/null ]    || mknod -m 666 /lindfs/dev/null    c 1 3; } \
 && { [ -e /lindfs/dev/random ]  || mknod -m 666 /lindfs/dev/random  c 1 8; } \
 && { [ -e /lindfs/dev/urandom ] || mknod -m 666 /lindfs/dev/urandom c 1 9; } \
 && ls -l /lindfs/dev


# TODO: test stage, once test scripts are ready.
# FROM build AS test
# ...run tests per app with continue-and-record, write results to $RESULTS_DIR...


# Export build results only: docker build --target artifacts --output type=local,dest=<dir> .
FROM scratch AS artifacts
COPY --from=build /apps-results /