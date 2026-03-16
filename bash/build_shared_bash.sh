/home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang \
    --target=wasm32-unknown-wasi \
    --sysroot=/home/lind/lind-wasm-apps/build/sysroot_merged \
    -fPIC \
    -pthread \
    -L./builtins -L./lib/readline -L./lib/glob -L./lib/tilde -L./lib/sh \
    -Wl,-pie \
    -Wl,--import-table \
    -Wl,--import-memory \
    -Wl,--export-memory \
    -Wl,--max-memory=67108864 \
    -Wl,--export=__stack_pointer \
    -Wl,--export=__stack_low \
    -Wl,--allow-undefined \
    -Wl,--unresolved-symbols=import-dynamic \
    -o ./bash.raw.wasm \
    /home/lind/lind-wasm-apps/bash/locale_stub.o /home/lind/lind-wasm-apps/bash/getgroups_stub.o shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o bashhist.o bashline.o siglist.o list.o stringlib.o locale.o findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o /home/lind/lind-wasm-apps/bash/tputs_stub.o /home/lind/lind-wasm/src/glibc/build/lind_debug.o /home/lind/lind-wasm/src/glibc/build/csu/set_stack_pointer.o -lbuiltins -lglob -lsh -lreadline -lhistory -ltilde

/home/lind/lind-wasm/scripts/append_stack_pointer_export.sh ./bash.raw.wasm ./bash.raw.wasm
/home/lind/binaryen-epoch-injection/bin/wasm-opt --enable-bulk-memory --enable-threads --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module --asyncify --pass-arg=asyncify-import-globals -O2 --debuginfo ./bash.raw.wasm -o ./bash.wasm
sudo /home/lind/lind-wasm/src/lind-boot/target/debug/lind-boot --precompile ./bash.wasm
cp ./bash.cwasm /home/lind/lind-wasm/lindfs/bin/
