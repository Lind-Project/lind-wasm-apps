/*
 * WASI stubs for PostgreSQL
 *
 * Provides stub implementations for POSIX functions that are referenced by
 * the PostgreSQL backend but not available in the WASI sysroot.  These are
 * sufficient for running in single-user mode (postgres --single).
 */

#include <errno.h>
#include <stddef.h>
#include <sys/types.h>

/* ----------------------------------------------------------------
 * fork() — single-user mode never forks; return error.
 * ---------------------------------------------------------------- */
pid_t fork(void)
{
    errno = ENOSYS;
    return -1;
}

/* ----------------------------------------------------------------
 * syslog family — no-ops (WASI has no syslog daemon).
 * ---------------------------------------------------------------- */
void openlog(const char *ident, int option, int facility)
{
    (void)ident; (void)option; (void)facility;
}

void syslog(int priority, const char *fmt, ...)
{
    (void)priority; (void)fmt;
}

void closelog(void)
{
}

/* ----------------------------------------------------------------
 * getrlimit / setrlimit — return success with generous defaults.
 * ---------------------------------------------------------------- */
#ifndef RLIMIT_NOFILE
#define RLIMIT_NOFILE 7
#endif

struct rlimit {
    unsigned long rlim_cur;
    unsigned long rlim_max;
};

int getrlimit(int resource, struct rlimit *rlim)
{
    (void)resource;
    if (rlim) {
        rlim->rlim_cur = 1024;
        rlim->rlim_max = 1024;
    }
    return 0;
}

int setrlimit(int resource, const struct rlimit *rlim)
{
    (void)resource; (void)rlim;
    return 0;
}

/* getpeereid — provided by libpgport_srv.a(getpeereid_srv.o), not stubbed here */

/* ----------------------------------------------------------------
 * getpwuid_r / getpwnam_r — return "not found" (no passwd db).
 * ---------------------------------------------------------------- */
struct passwd;

int getpwuid_r(uid_t uid, struct passwd *pwd, char *buf, size_t buflen,
               struct passwd **result)
{
    (void)uid; (void)pwd; (void)buf; (void)buflen;
    if (result)
        *result = NULL;
    return 0;
}

int getpwnam_r(const char *name, struct passwd *pwd, char *buf, size_t buflen,
               struct passwd **result)
{
    (void)name; (void)pwd; (void)buf; (void)buflen;
    if (result)
        *result = NULL;
    return 0;
}

/* ----------------------------------------------------------------
 * kill — no signals in WASI; succeed silently.
 * ---------------------------------------------------------------- */
int kill(pid_t pid, int sig)
{
    (void)pid; (void)sig;
    return 0;
}

/* ----------------------------------------------------------------
 * getrusage — return zeroed-out structure.
 * ---------------------------------------------------------------- */
struct rusage {
    struct { long tv_sec; long tv_usec; } ru_utime;
    struct { long tv_sec; long tv_usec; } ru_stime;
    long ru_maxrss;
    long ru_ixrss, ru_idrss, ru_isrss;
    long ru_minflt, ru_majflt, ru_nswap;
    long ru_inblock, ru_oublock;
    long ru_msgsnd, ru_msgrcv;
    long ru_nsignals;
    long ru_nvcsw, ru_nivcsw;
};

#ifndef RUSAGE_SELF
#define RUSAGE_SELF 0
#endif

int getrusage(int who, struct rusage *usage)
{
    (void)who;
    if (usage) {
        char *p = (char *)usage;
        for (size_t i = 0; i < sizeof(*usage); i++)
            p[i] = 0;
    }
    return 0;
}

/* ----------------------------------------------------------------
 * Shared memory stubs — single-user mode with EXEC_BACKEND off
 * won't actually use SysV shm, but the symbols may be referenced.
 * ---------------------------------------------------------------- */
int shmget(int key, size_t size, int shmflg)
{
    (void)key; (void)size; (void)shmflg;
    errno = ENOSYS;
    return -1;
}

void *shmat(int shmid, const void *shmaddr, int shmflg)
{
    (void)shmid; (void)shmaddr; (void)shmflg;
    errno = ENOSYS;
    return (void *)-1;
}

int shmdt(const void *shmaddr)
{
    (void)shmaddr;
    errno = ENOSYS;
    return -1;
}

int shmctl(int shmid, int cmd, void *buf)
{
    (void)shmid; (void)cmd; (void)buf;
    errno = ENOSYS;
    return -1;
}

/* ----------------------------------------------------------------
 * Semaphore stubs — PG uses these for multi-process sync; in
 * single-user mode they are not exercised, but symbols are needed.
 * ---------------------------------------------------------------- */
typedef int sem_t;

int sem_init(sem_t *sem, int pshared, unsigned int value)
{
    (void)sem; (void)pshared; (void)value;
    return 0;
}

int sem_destroy(sem_t *sem)
{
    (void)sem;
    return 0;
}

int sem_post(sem_t *sem)
{
    (void)sem;
    return 0;
}

int sem_wait(sem_t *sem)
{
    (void)sem;
    return 0;
}

int sem_trywait(sem_t *sem)
{
    (void)sem;
    return 0;
}

/* Signal functions — provided by the lind-wasm sysroot, not stubbed here */

/* ----------------------------------------------------------------
 * Miscellaneous stubs
 * ---------------------------------------------------------------- */

/* getpgrp — process groups don't exist in WASI */
pid_t getpgrp(void)
{
    return 1;
}

/* setpgid — provided by libc.a, not stubbed here */

pid_t setsid(void)
{
    return 1;
}

/* getaddrinfo-related — basic networking stubs */
int getifaddrs(void *ifap)
{
    (void)ifap;
    errno = ENOSYS;
    return -1;
}

void freeifaddrs(void *ifa)
{
    (void)ifa;
}

/* sync_file_range — not available in WASI */
int sync_file_range(int fd, long long offset, long long nbytes, unsigned int flags)
{
    (void)fd; (void)offset; (void)nbytes; (void)flags;
    return 0;
}

/* posix_fallocate — not available in WASI */
int posix_fallocate(int fd, long long offset, long long len)
{
    (void)fd; (void)offset; (void)len;
    return 0;
}

/* ppoll — not available in WASI */
int ppoll(void *fds, unsigned long nfds, const void *tmo_p, const void *sigmask)
{
    (void)fds; (void)nfds; (void)tmo_p; (void)sigmask;
    errno = ENOSYS;
    return -1;
}

/* ----------------------------------------------------------------
 * _Unwind_* stubs — pulled in by libc's backtrace.o; the WASI
 * target has no stack unwinder so these are no-ops.
 * ---------------------------------------------------------------- */
typedef unsigned int _Unwind_Reason_Code;
typedef void *_Unwind_Context;
typedef _Unwind_Reason_Code (*_Unwind_Trace_Fn)(_Unwind_Context *, void *);

_Unwind_Reason_Code _Unwind_Backtrace(_Unwind_Trace_Fn fn, void *arg)
{
    (void)fn; (void)arg;
    return 0; /* _URC_NO_REASON — just report no frames */
}

unsigned long _Unwind_GetIP(_Unwind_Context *ctx)
{
    (void)ctx;
    return 0;
}

unsigned long _Unwind_GetGR(_Unwind_Context *ctx, int index)
{
    (void)ctx; (void)index;
    return 0;
}

unsigned long _Unwind_GetCFA(_Unwind_Context *ctx)
{
    (void)ctx;
    return 0;
}
