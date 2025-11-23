#!/bin/bash

# cd python-native

# ./configure #build a native version of Python to get pgen from
# touch Include/Python-ast.h Python/Python-ast.c
# make Parser/pgen #build a native version of Python to get pgen from

# cd ..

# if [[ "$*" =~ (^|[[:blank:]])(-h|--help)([[:blank:]]|$) ]]; then
#     ./configure --help
#     exit 1
# fi

# NOTE: make a native build of cpython 3.14 and replace the path for --with-build-python
./configure \
    --host=wasm32-unknown-wasi \
    --build=x86_64-unknown-linux-gnu \
    --with-build-python=../native-cpython-3.14/python \
    CC="/home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang \
    -pthread \
    --target=wasm32-unknown-wasi \
    --sysroot /home/lind/lind-wasm/src/glibc/sysroot \
    -Wl,--import-memory,--export-memory,--max-memory=2147483648,-z,stack-size=1073741824,--export=__stack_pointer,--export=__stack_low -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0" \
    ac_cv_func_working_mktime=yes \
    ac_cv_func_mmap_fixed_mapped=yes \
    bash_cv_func_sigsetjmp=no \
    ac_cv_func_localeconv=no \
    ac_cv_func_uselocale=no \
    ac_cv_func_setlocale=no \
    ac_cv_func_newlocale=no \
    ac_cv_have_chflags=no \
    ax_cv_c_float_words_bigendian=no \
    ac_cv_file__dev_ptmx=no \
    ac_cv_file__dev_ptc=no \
    --verbose > configure.log

# cp "./Modules/Setup.dist"  "./Modules/Setup"

# touch Include/Python-ast.h Python/Python-ast.c

make AR="llvm-ar" ARFLAGS="crs" RANLIB="echo" CFLAGS="--debug" V=1 > check.log

# cp python-native/Parser/pgen Parser/pgen && chmod +x Parser/pgen

# make AR="llvm-ar" ARFLAGS="crs" RANLIB="echo" CFLAGS="--debug" V=1 >> check.log
