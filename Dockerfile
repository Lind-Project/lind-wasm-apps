ARG ARTIFACT_MODE=fast

FROM securesystemslab/lind-wasm-dev:latest AS src

COPY --chown=lind:lind . /home/lind/lind-wasm/lind-wasm-apps
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

# Stage 1: shared setup that multiple app builds depend on.
FROM src AS shared
RUN make -j"$(nproc)" -Otarget preflight merge-base-sysroot libtirpc >/dev/null 2>&1

# Stage 2: build apps in sibling stages so BuildKit can schedule them in parallel.
# Cap per-stage JOBS so concurrent stages do not all try to consume the full machine.
FROM shared AS nginx-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" nginx >/dev/null 2>&1

FROM shared AS bash-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" bash >/dev/null 2>&1

FROM shared AS coreutils-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" coreutils >/dev/null 2>&1

FROM shared AS lmbench-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" lmbench >/dev/null 2>&1

# Stage 3: final image
FROM securesystemslab/lind-wasm-dev:latest
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

# 1) Copy the full workspace ONCE (baseline)
COPY --from=shared --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps \
  /home/lind/lind-wasm/lind-wasm-apps

# 2) Overlay only the build outputs from each sibling stage.
COPY --from=nginx-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/nginx \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/nginx

COPY --from=bash-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/bash \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/bash

COPY --from=coreutils-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/coreutils \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/coreutils

COPY --from=lmbench-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/lmbench \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/lmbench
