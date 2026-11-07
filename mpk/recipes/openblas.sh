# OpenBLAS (no Fortran; single-threaded) + its C unit tests (utest)
KIND=library
NOTE="Built with NOFORTRAN=1 USE_THREAD=0 TARGET=GENERIC: no gfortran in the dev image, and the HASWELL kernels use AVX (vmovupd), which gsfork-elf rejects."
recipe_build() {
  local opts=(CC="$MPK_CC" HOSTCC=gcc NOFORTRAN=1 USE_THREAD=0 USE_OPENMP=0 NO_SHARED=1
              TARGET=GENERIC DYNAMIC_ARCH=0 NUM_THREADS=1)
  make -j"$JOBS" "${opts[@]}" libs netlib
  make "${opts[@]}" -C utest openblas_utest
  stage_bin utest/openblas_utest /usr/local/bin/openblas_utest
  cat > dgemm_check.c <<'C'
#include <stdio.h>
#include "cblas.h"
int main(void) {
  double a[4] = {1, 2, 3, 4}, b[4] = {5, 6, 7, 8}, c[4] = {0};
  cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2, 1.0, a, 2, b, 2, 0.0, c, 2);
  printf("dgemm %g %g %g %g\n", c[0], c[1], c[2], c[3]);
  return !(c[0] == 19 && c[1] == 22 && c[2] == 43 && c[3] == 50);
}
C
  "$MPK_CC" $CFLAGS -I. dgemm_check.c -o dgemm_check libopenblas.a -lm -lpthread
  stage_bin dgemm_check /usr/local/bin/openblas_dgemm_check
}
recipe_smoke() {
  smoke dgemm "dgemm 19 22 43 50" -- /usr/local/bin/openblas_dgemm_check
  SMOKE_TIMEOUT=300 smoke utest "SUCCESS" -- /usr/local/bin/openblas_utest
}
