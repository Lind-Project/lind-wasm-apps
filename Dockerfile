FROM securesystemslab/lind-wasm-dev:latest

COPY . /home/lind/lind-wasm/lind-wasm-apps
WORKDIR /home/lind/lind-wasm/lind-wasm-apps

RUN make bash nginx lmbench coreutils
