# in-toto on lind-wasm

A small command-line tool over the Rust [`in-toto`](https://crates.io/crates/in-toto)
crate. It runs the in-toto supply chain demo inside lind: record a step, sign
the record, verify the chain against a layout.

This is the first Rust application in this repo.

## Commands

```
in-toto-cli keygen     <out.pk8> <out.pub.json>
in-toto-cli run        --name <step> --key <pk8> --out <link-dir> [--materials p..] [--products p..] [--lstrip <prefix>] [-- <cmd> <args..>]
in-toto-cli gen-layout --key <owner.pk8> --step-key <functionary.pub.json> --out <root.layout> [--expires <RFC3339>]
                       [--src <file>] [--pkg <file>] [--step-src <name>] [--step-pkg <name>] [-- <expected cmd>]
in-toto-cli verify     --layout <root.layout> --key <owner.pub.json> --links <link-dir>
```

`run` records a step. It hashes the materials, runs the command after `--`
if there is one, hashes the products, and signs the link. The command's exit
status and arguments go into the link.

`gen-layout` writes a two-step layout. The first step creates `<src>`. The
second step consumes `<src>` and creates `<pkg>`. The defaults are the classic
`write-code` and `package` steps with `foo.py` and `foo.tar.gz`.

## How the command runs

`std::process` does not work on wasm32-wasip1. The command is started with
libc `fork`, `execv` and `waitpid` instead. This is how the Rust grates launch
their child.

Under lind the child is a new cage. A grate wrapping in-toto-cli sees the
child too. The gcc example below relies on this.

## Build

You need the lind-wasm sysroot, `build/lind-boot`, and the Rust toolchain
`nightly-2026-02-11` with `rust-src`. The dev image has all three.

```
make in-toto           # build/in-toto/usr/local/bin/in-toto-cli
make install-in-toto   # copy into $LINDFS_ROOT
```

`compile_in-toto.sh` builds the same way as `cargo-lind_compile` in lind-wasm.
It also applies the lind overlay for the Rust `libc` crate. Without the
overlay `std::fs` returns wrong file sizes and directory listings on lind,
and in-toto cannot record artifacts. See `docs/contribute/compile-with-rust.md`
in lind-wasm for details.

Known gap: `std::thread::spawn` aborts on lind. in-toto does not use threads.

## Test

```
./run_tests.sh --native   # host build
./run_tests.sh            # lind build, runs under lind_run with sudo
```

Both modes run the same seven checks and produce the same link hashes.

## Example: gcc attested by in-toto

`examples/gcc-imfs.sh` runs gcc under the IMFS grate with in-toto recording
the build.

1. A `write-code` step records `hello.c`.
2. A `build` step runs in-toto-cli under the IMFS grate. in-toto forks gcc,
   gcc writes the ELF into the in-memory filesystem, and in-toto signs a link
   with the ELF's hash.
3. `gen-layout` ties the two steps together and `verify` passes.
4. `hello.c` is tampered and rebuilt. `verify` fails.

The script needs the gcc closure and the IMFS grate staged in `lindfs`. The
required files are listed in `examples/gcc-preloads.txt`. The ELF built under
the grate is byte-identical to one built without it.
