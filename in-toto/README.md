# in-toto (Rust) on lind-wasm

First Rust app in lind-wasm-apps. A small CLI over the
[`in-toto`](https://crates.io/crates/in-toto) crate (v0.4, library only,
crypto via ring) so the classic two-step in-toto demo runs inside lind.

```
in-toto-cli keygen     <out.pk8> <out.pub.json>
in-toto-cli run        --name <step> --key <pk8> --out <link-dir> [--materials p..] [--products p..] [--lstrip <prefix>]
in-toto-cli gen-layout --key <owner.pk8> --step-key <functionary.pub.json> --out <root.layout> [--expires <RFC3339>]
in-toto-cli verify     --layout <root.layout> --key <owner.pub.json> --links <link-dir>
```

`run` does not execute a command (`std::process` is unsupported on
wasm32-wasip1). It only hashes and signs artifacts the caller created.

## Build

Needs the lind-wasm sysroot, `build/lind-boot`, and Rust `nightly-2026-02-11`
with `rust-src` (the dev image has all three).

```
make in-toto           # build/in-toto/usr/local/bin/in-toto-cli
make install-in-toto   # copy into $LINDFS_ROOT
```

`compile_in-toto.sh` follows `lind-wasm/scripts/bin/cargo-lind_compile`
(cargo `-Z build-std` on wasm32-wasip1, `wasip1-clang.sh` linker,
`lind-wasm-opt --static`, `lind-boot --precompile`). It also runs
`lind-wasm/scripts/rust/make_lind_libc.sh --patch-std`, a lind overlay of the
Rust `libc` crate. Without it `std::fs::metadata`, `read_dir` and
`File::create` are broken on lind and in-toto cannot record artifacts.
See `docs/contribute/compile-with-rust.md` in lind-wasm. Known gap:
`std::thread::spawn` aborts on lind; in-toto does not use threads.

## Test

```
./run_tests.sh --native   # host build
./run_tests.sh            # lind build under lind_run (sudo)
```

Both pass 6/6 (2026-09-10, lind-wasm `main`). Link hashes match between them.
