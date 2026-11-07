# GNU binutils + gas + ld
recipe_build() {
  autotools_touch
  mpk_configure --disable-nls --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng \
    --disable-werror --without-zstd --without-debuginfod --disable-plugins MAKEINFO=true
  make -j"$JOBS" MAKEINFO=true all-binutils all-gas all-ld
  local b
  for b in binutils/{objdump,readelf,nm-new,size,strings,ar,objcopy,strip-new,addr2line,cxxfilt,ranlib} gas/as-new ld/ld-new; do
    local n; n="$(basename "$b")"; n="${n%-new}"; [[ $n == cxxfilt ]] && n=c++filt
    stage_bin "$b" "/usr/local/bin/$n"
  done
}
recipe_smoke() {
  fixture /tmp/mpk-binutils/t.s <<'ASM'
  .globl _start
  .text
_start:
  mov $60, %eax
  mov $42, %edi
  syscall
ASM
  local d=/tmp/mpk-binutils
  smoke version "GNU objdump" -- /usr/local/bin/objdump --version
  smoke as "" -- /usr/local/bin/as -o $d/t.o $d/t.s
  smoke ld "" -- /usr/local/bin/ld -o $d/t $d/t.o
  smoke readelf "EXEC" -- /usr/local/bin/readelf -h $d/t
  smoke objdump "syscall" -- /usr/local/bin/objdump -d $d/t
  smoke nm "_start" -- /usr/local/bin/nm $d/t.o
  smoke ar "t.o" -- /usr/local/bin/ar rcsv $d/libt.a $d/t.o
  smoke objcopy "" -- /usr/local/bin/objcopy -O binary $d/t $d/t.bin
  smoke size "text" -- /usr/local/bin/size $d/t
  smoke strings "GNU" -- /usr/local/bin/strings /usr/local/bin/objdump
}
