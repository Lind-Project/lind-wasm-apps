FROM securesystemslab/lind-wasm-dev:latest

COPY --chown=lind:lind . /home/lind/lind-wasm/lind-wasm-apps
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

RUN make -j"$(nproc)" -Otarget bash nginx lmbench coreutils