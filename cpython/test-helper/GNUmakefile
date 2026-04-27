# This file persists across configure re-runs (configure only generates Makefile, not GNUmakefile).
#
# Test strategy: native python orchestrates the test runner (workers, IPC, queue),
# lind-wasm runs each individual test subprocess via --python.
# This mirrors the original WASI cross-build test mode.
LIND_PYTHON = lind-wasm --preload env=lib/libpython3.14.so --env TMPDIR=/tmp usr/local/bin/python

include Makefile

# Tests that hang in lind due to unimplemented fork-in-multithreaded-process,
# broken threading primitives, or other lind limitations.
LIND_SKIP = \
	-x test_coroutines \
	-x test_thread \
	-x test_threading \
	-x test_threadsignals \
	-x test_queue \
	-x test_poll \
	-x test_logging \
	-x test_httpservers \
	-x test_wsgiref \
	-x test_support \
	-x test_pickle \
	-x test_cmd_line_script \
	-x test__interpchannels \
	-x test_asyncio \
	-x test_concurrent_futures \
	-x test_multiprocessing_fork

# Override test target: native python orchestrates, lind-wasm runs each test.
test:
	$(RUNSHARED) $(PYTHON_FOR_BUILD) -m test --fast-ci -u-gui --timeout=$(TESTTIMEOUT) \
		--python="$(LIND_PYTHON)" $(LIND_SKIP) $(TESTOPTS)
