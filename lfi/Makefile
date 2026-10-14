# LFI build of the apps. Needs LFI_ROOT (a bootstrapped, built lind-lfi checkout); see README.md.
#   make              build the first category
#   make test         smoke tests, directly and under the strace grate
#   make APPS="sed grep" ...
APPS ?= sed grep awk diffutils make coreutils zlib
all: $(APPS)
$(APPS):
	./build-app.sh $@
test:
	./test.sh
	WRAP=strace ./test.sh
clean:
	rm -rf ../build-lfi
.PHONY: all test clean $(APPS)
