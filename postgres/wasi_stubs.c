/*
 * WASI stubs for PostgreSQL
 *
 * Only stubs for symbols that are genuinely missing from the lind-wasm
 * sysroot.  Most POSIX functions (fork, signals, semaphores, shared memory,
 * getrlimit, kill, getrusage, ppoll, etc.) are provided by the sysroot's
 * glibc and should NOT be stubbed here.
 */

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

/* Wrapper for encoding function - libpgcommon exports _private suffix */
extern int pg_valid_server_encoding_id_private(int encoding);
int pg_valid_server_encoding_id(int encoding) {
    return pg_valid_server_encoding_id_private(encoding);
}
