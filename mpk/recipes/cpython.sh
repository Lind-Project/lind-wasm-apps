# CPython with all stdlib extension modules linked statically into the interpreter
# (lindfs has no rewritten lib-dynload .so files). Optional third-party-backed
# modules whose libraries are missing from lind (ssl, sqlite3, ctypes, ...) are off.
DEPS=(zlib)
RUNTIME_DEPS=(bash coreutils)
UPSTREAM_TESTS=0
NOTE="Upstream run_tests.sh drives 'make test' from a wasm build tree (build-wasm/); replaced by stdlib smoke tests."
recipe_build() {
  autotools_touch
  local na=(_ssl _hashlib _sqlite3 _bz2 _lzma _ctypes _ctypes_test _tkinter _curses
            _curses_panel readline _dbm _gdbm _uuid nis _testcapi _testinternalcapi
            _testlimitedcapi _testbuffer _testimportmultiple _testmultiphase
            _testsinglephase _testexternalinspection _testclinic _testclinic_limited
            xxsubtype xxlimited xxlimited_35 _xxtestfuzz _decimal _crypt _remote_debugging _zstd)
  local m env=()
  for m in "${na[@]}"; do env+=("py_cv_module_$m=n/a"); done
  env "${env[@]}" ZLIB_CFLAGS="-I$PREFIX/include" ZLIB_LIBS="$PREFIX/lib/libz.a" \
    ./configure CC="$MPK_CC" CXX="$MPK_CXX" --prefix=/usr/local --without-ensurepip \
      --disable-shared --disable-test-modules --without-readline
  { echo '*static*'; grep -vE '^\*|^#' Modules/Setup.stdlib; } > Modules/Setup.local
  # Static modules share HACL objects; link the archives instead of overlapping object lists.
  sed -i -E '/^MODULE__/s/(LIBHACL_[A-Z0-9_]+)_LIB_SHARED/\1_LIB_STATIC/g' Makefile.pre
  make Makefile
  make -j"$JOBS"
  make DESTDIR="$SRC/inst" install
  local ver; ver="$(ls "$SRC/inst/usr/local/lib" | grep -E '^python3\.[0-9]+$' | head -1)"
  mkdir -p "$NATIVE/usr/local/lib"
  rsync -a --exclude test --exclude idlelib --exclude tkinter --exclude turtledemo \
    --exclude __pycache__ --exclude lib-dynload "$SRC/inst/usr/local/lib/$ver" "$NATIVE/usr/local/lib/"
  stage_bin "$SRC/inst/usr/local/bin/$ver" /usr/local/bin/python
  ln -sf python "$NATIVE/usr/local/bin/python3"
}
recipe_smoke() {
  local py=/usr/local/bin/python
  smoke version "Python 3" -- $py --version
  smoke print "hello mpk" -- $py -c 'print("hello mpk")'
  smoke stdlib "ok" -- $py -c 'import json, re, collections, itertools, hashlib, struct, math; assert json.loads(json.dumps({"a": [1, 2]}))["a"][1] == 2; assert re.sub(r"\d", "x", "a1") == "ax"; print("ok")'
  smoke zlib "roundtrip ok" -- $py -c 'import zlib; d = b"lind" * 1000; assert zlib.decompress(zlib.compress(d)) == d; print("roundtrip ok")'
  smoke sha256 "2cf24dba5fb0a30e" -- $py -c 'import hashlib; print(hashlib.sha256(b"hello").hexdigest())'
  smoke files "3 lines" -- $py -c 'import os, tempfile; p = "/tmp/mpk-py.txt"; open(p, "w").write("a\nb\nc\n"); print(len(open(p).readlines()), "lines"); os.remove(p)'
  smoke threads "sum 4950" -- $py -c 'import threading; r = []; ts = [threading.Thread(target=r.append, args=(i,)) for i in range(100)]; [t.start() for t in ts]; [t.join() for t in ts]; print("sum", sum(r))'
  smoke fork "child 3" -- $py -c 'import os; p = os.fork(); os._exit(3) if p == 0 else print("child", os.waitstatus_to_exitcode(os.waitpid(p, 0)[1]))'
  smoke subprocess "from-sh" -- $py -c 'import subprocess; print(subprocess.run(["/bin/sh", "-c", "echo from-sh"], capture_output=True, text=True).stdout)'
  smoke socket "pong" -- $py -c 'import socket; a, b = socket.socketpair(); a.sendall(b"pong"); print(b.recv(4).decode())'
}
