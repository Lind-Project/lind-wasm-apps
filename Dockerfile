ARG ARTIFACT_MODE=fast

FROM securesystemslab/lind-wasm-dev:latest AS src

COPY --chown=lind:lind . /home/lind/lind-wasm/lind-wasm-apps
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

# Stage 1: shared setup that multiple app builds depend on.
FROM src AS shared
RUN make -j"$(nproc)" -Otarget preflight merge-base-sysroot libtirpc

# Stage 2: build apps in sibling stages so BuildKit can schedule them in parallel.
# Cap per-stage JOBS so concurrent stages do not all try to consume the full machine.
FROM shared AS bash-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" bash

FROM shared AS coreutils-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" coreutils

FROM shared AS cpython-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" cpython

FROM shared AS lmbench-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" lmbench

FROM shared AS sed-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" sed

FROM shared AS nginx-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" nginx

FROM shared AS grep-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" grep

FROM shared AS curl-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" curl

FROM shared AS git-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" git

FROM shared AS postgres-build
ARG ARTIFACT_MODE
RUN jobs="$(nproc)"; app_jobs="$(( jobs ))"; if [ "$app_jobs" -lt 1 ]; then app_jobs=1; fi; \
    make -Otarget JOBS="$app_jobs" ARTIFACT_MODE="$ARTIFACT_MODE" postgres

# Stage 3: final image
FROM securesystemslab/lind-wasm-dev:latest
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

# 1) Copy the full workspace ONCE (baseline)
COPY --from=shared --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps \
  /home/lind/lind-wasm/lind-wasm-apps

# 2) Overlay only the build outputs from each sibling stage.
COPY --from=bash-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/bash \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/bash

COPY --from=coreutils-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/coreutils \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/coreutils

COPY --from=cpython-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/cpython \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/cpython

COPY --from=lmbench-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/lmbench \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/lmbench

COPY --from=sed-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/sed \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/sed

COPY --from=nginx-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/nginx \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/nginx

COPY --from=grep-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/grep \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/grep

COPY --from=curl-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/curl \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/curl

COPY --from=git-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/git \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/git

COPY --from=postgres-build --chown=lind:lind \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/postgres \
  /home/lind/lind-wasm/lind-wasm-apps/build/bin/postgres

# 3) Ensure lindfs exists in the final image.
WORKDIR /home/lind/lind-wasm
RUN make -Otarget lindfs && \
    mkdir -p lindfs/dev && \
    rm -f lindfs/dev/null && \
    (mknod lindfs/dev/null c 1 3 || touch lindfs/dev/null) && \
    chmod 666 lindfs/dev/null

WORKDIR /home/lind/lind-wasm/lind-wasm-apps
