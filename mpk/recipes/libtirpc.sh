# libtirpc: static library (used by lmbench lat_rpc) plus an XDR round-trip program
KIND=library
recipe_build() {
  autoreconf -fi
  ./configure CC="$MPK_CC" --prefix="$PREFIX" --disable-shared --enable-static --disable-gssapi
  make -j"$JOBS"
  make install
  cat > xdr_check.c <<'C'
#include <rpc/rpc.h>
#include <stdio.h>
int main(void) {
  char buf[64]; XDR x; int v = 424242; char *s = "lind-mpk", *t = NULL; int out = 0;
  xdrmem_create(&x, buf, sizeof buf, XDR_ENCODE);
  if (!xdr_int(&x, &v) || !xdr_string(&x, &s, 32)) return 1;
  xdrmem_create(&x, buf, sizeof buf, XDR_DECODE);
  if (!xdr_int(&x, &out) || !xdr_string(&x, &t, 32)) return 2;
  printf("xdr %d %s\n", out, t);
  return out == v ? 0 : 3;
}
C
  "$MPK_CC" $CFLAGS -I"$PREFIX/include/tirpc" xdr_check.c -o xdr_check "$PREFIX/lib/libtirpc.a" -lpthread
  stage_bin xdr_check /usr/local/bin/tirpc-xdr-check
}
recipe_smoke() {
  smoke xdr-roundtrip "xdr 424242 lind-mpk" -- /usr/local/bin/tirpc-xdr-check
}
