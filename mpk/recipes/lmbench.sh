# lmbench micro-benchmarks (the set in expected-binaries.txt), libtirpc for lat_rpc
DEPS=(libtirpc)
recipe_build() {
  cd src
  local cflags=($CFLAGS -DNO_PORTMAPPER -DHAVE_uint=1 -DHAVE_uint64_t=1 -DHAVE_int64_t=1
                -DHAVE_socklen_t=1 -DHAVE_DRAND48 -DHAVE_SCHED_SETAFFINITY=1 -I"$PREFIX/include/tirpc")
  local lib=(lib_tcp.c lib_udp.c lib_unix.c lib_timing.c lib_mem.c lib_stats.c lib_debug.c lib_sched.c getopt.c)
  local b
  for b in $(grep -v '^#' ../expected-binaries.txt); do
    b="$(basename "$b")"
    local extra=()
    [ "$b" = flushdisk ] && extra=(-DMAIN)
    "$MPK_CC" "${cflags[@]}" "${extra[@]}" -o "$b" "$b.c" "${lib[@]}" "$PREFIX/lib/libtirpc.a" -lm -lpthread
    stage_bin "$b" "/bin/$b"
  done
}
recipe_smoke() {
  dd if=/dev/zero of="$LINDFS/tmp/mpk-lmbench.dat" bs=1M count=4 status=none
  smoke hello "Hello world" -- /bin/hello
  smoke lat_syscall-null "Simple syscall" -- /bin/lat_syscall -N 1 null
  smoke lat_syscall-read "Simple read" -- /bin/lat_syscall -N 1 read
  smoke lat_pipe "Pipe latency" -- /bin/lat_pipe -N 1
  smoke lat_proc-fork "Process fork" -- /bin/lat_proc -N 1 fork
  smoke bw_mem "" -- /bin/bw_mem -N 1 1m rd
  smoke bw_file_rd "" -- /bin/bw_file_rd -N 1 1m io_only /tmp/mpk-lmbench.dat
  smoke lat_mmap "" -- /bin/lat_mmap -N 1 1m /tmp/mpk-lmbench.dat
  smoke bw_pipe "" -- /bin/bw_pipe -N 1
  smoke lat_select "" -- /bin/lat_select -N 1 -n 10 file
}
