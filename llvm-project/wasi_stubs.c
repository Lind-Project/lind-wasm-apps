// WASI stubs for symbols missing from the glibc sysroot.
// These should be removed once the proper fixes land in lind-wasm's glibc.
// See: alice-clang branch diff (weak_alias for sigaltstack in sigaltstack.c)

#include <signal.h>
#include <errno.h>

int sigaltstack(const stack_t *ss, stack_t *old_ss) {
    (void)ss;
    (void)old_ss;
    errno = ENOSYS;
    return -1;
}
