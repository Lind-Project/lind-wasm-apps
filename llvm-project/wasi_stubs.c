// WASI stubs for symbols missing from the glibc sysroot.
// These should be removed once the proper fixes land in lind-wasm's glibc.
// See: alice-clang branch diff (weak_alias for sigaltstack in sigaltstack.c)

#include <signal.h>
#include <errno.h>
#include <stdint.h>

// sigaltstack — WASI has no signal stacks; pretend success so LLVM's
// signal handler setup doesn't fail.
int sigaltstack(const stack_t *ss, stack_t *old_ss) {
    (void)ss;
    (void)old_ss;
    return 0;
}

// glibc's sysconf_sigstksz() reads GLRO(dl_minsigstacksize) and asserts
// it's non-zero.  In WASI there's no kernel AT_MINSIGSTKSZ auxval to
// initialize it, so provide a reasonable default (MINSIGSTKSZ = 2048).
unsigned long _dl_minsigstacksize = 2048;
