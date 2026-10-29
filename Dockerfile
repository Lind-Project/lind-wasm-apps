# syntax=docker/dockerfile:1.7-labs

# Build and test lind-wasm-apps on the lind-wasm release image.
#
# Stages:
#   build     - set up the build, build apps, install them into /lindfs, and prepare /lindfs to run them
#   test      - run app tests
#   artifacts - results only (results.tsv, test-results.tsv, env.txt, logs/)
#
# App build or test failures do not fail `docker build`.
# Check results.tsv and test-results.tsv.
#
# Usage (from the repo root):
#   docker build --platform=linux/amd64 \
#     --build-arg APPS_COMMIT=$(git rev-parse HEAD) \
#     --target artifacts --output type=local,dest=./apps-results .
#
# To run the tests again without changes, add --no-cache-filter test.
# Otherwise Docker reuses the cached test results.

# Release image with the fpcast runtime in /prebuilt-lindfs-fpcast/lib.
ARG BASE_IMAGE=securesystemslab/lind-wasm:latest

FROM ${BASE_IMAGE} AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# clang is not built: its build script fails ("LD: unbound variable").
ARG APPS="lmbench bash nginx coreutils git curl grep sed binutils diffutils perl awk gmake tinycc cpython postgres gcc"
# Not named LIBS: ARGs become env vars, and configure reads LIBS.
ARG INSTALL_LIBS="libtirpc gnulib zlib openssl libcxx"
# Passed in because .git is not in the build context.
ARG APPS_COMMIT=unknown

ENV RESULTS_DIR=/apps-results

WORKDIR /apps
COPY . /apps

RUN mkdir -p "$RESULTS_DIR/logs" \
 && { echo "date: $(date -Is)"; \
      echo "apps_commit: ${APPS_COMMIT}"; \
      echo "nproc: $(nproc)"; \
      make -C /apps print-config; } > "$RESULTS_DIR/env.txt" 2>&1 \
 && printf "target\texit\tseconds\n" > "$RESULTS_DIR/results.tsv" \
 && cat "$RESULTS_DIR/env.txt"

# Step 1: prepare the toolchain and sysroot.
# Stop here if this fails. No app can build without it.
RUN make -C /apps preflight     2>&1 | tee "$RESULTS_DIR/logs/preflight.log" \
 && make -C /apps merge-sysroot 2>&1 | tee "$RESULTS_DIR/logs/merge-sysroot.log"

# Step 2: build each app with its own make call.
# A failed app is recorded, and the next app still builds.
RUN <<'EOF'
#!/usr/bin/env bash
set -uo pipefail   # no -e: record failures and keep going
for t in $APPS; do
  start=$(date +%s)
  # postgres: build one job at a time. Its build script removes and re-creates
  # header symlinks while other files compile, so it fails at random with -j.
  # TODO: remove after the build script is fixed.
  case "$t" in
    postgres) jobs="JOBS=1" ;;
    *)        jobs="" ;;
  esac
  make -C /apps "$t" $jobs > "$RESULTS_DIR/logs/$t.log" 2>&1
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

# Step 3: create the /lindfs folders and config files.
# The release image has only /lindfs/lib. Same as `make lindfs` in lind-wasm, except dev/null (see Step 6).
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

# Step 4: install the libraries, then only the apps that built.
# `make install` is not used: one unbuilt app would stop it.
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
# Print the summary with cat: `column` is not installed in the base image, and this is the last command, so its exit code becomes the RUN's exit code.
echo; cat "$RESULTS_DIR/results.tsv"
EOF

# Step 5: choose the libc/libm used at run time.
#   fpcast  - copy the fpcast libc/libm over the default ones (default).
#             Apps built with `wasm-opt --fpcast-emu` need this.
#   default - keep the default libc/libm of the release image.
# Runs after install, so install cannot overwrite it.
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

# Step 6: create /dev/null, /dev/random and /dev/urandom in /lindfs.
# Apps see /lindfs as "/", so they open these files there.
# A file made by `touch` is replaced with a real device file.
RUN mkdir -p /lindfs/dev \
 && { [ -c /lindfs/dev/null ]    || { rm -f /lindfs/dev/null;    mknod -m 666 /lindfs/dev/null    c 1 3; }; } \
 && { [ -c /lindfs/dev/random ]  || { rm -f /lindfs/dev/random;  mknod -m 666 /lindfs/dev/random  c 1 8; }; } \
 && { [ -c /lindfs/dev/urandom ] || { rm -f /lindfs/dev/urandom; mknod -m 666 /lindfs/dev/urandom c 1 9; }; } \
 && ls -l /lindfs/dev

# Step 7: keep LIND_WASM_ROOT when a test runs `sudo lind_run` (e.g. grep).
# sudo removes it, and lind_run cannot find lind-wasm without it
# in the release image.
RUN echo 'Defaults env_keep += "LIND_WASM_ROOT"' > /etc/sudoers.d/lind-wasm-root \
 && chmod 0440 /etc/sudoers.d/lind-wasm-root \
 && visudo -cf /etc/sudoers.d/lind-wasm-root


FROM build AS test

# Apps built with fpcast that have tests. 'make' is the test name for gmake.
# Not named TESTS: automake reads TESTS.
ARG TEST_APPS="awk bash coreutils grep make nginx perl"

# Test each app with its own `make test` call.
# A failed app is recorded, and the next app still runs.
# Apps that were not built or installed are recorded as "skipped".
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


# Copy only /apps-results out of the image.
FROM scratch AS artifacts
COPY --from=test /apps-results /