# GNU make
RUNTIME_DEPS=(bash coreutils)
recipe_build() {
  autotools_touch
  mpk_configure --disable-nls --without-guile
  make -j"$JOBS"
  stage_bin make /usr/local/bin/make
}
recipe_smoke() {
  printf 'all: dep\n\t@echo built-$@\ndep:\n\t@echo "dep via shell" | cat\n' | fixture /tmp/mpk-make/Makefile
  smoke version "GNU Make" -- /usr/local/bin/make --version
  smoke eval "77" -- /usr/local/bin/make -f /dev/null --eval 'x:=$(shell echo 77)' --eval '$(info $(x))'
  smoke recipe "built-all" -- /usr/local/bin/make -C /tmp/mpk-make
  smoke shell-recipe "dep via shell" -- /usr/local/bin/make -C /tmp/mpk-make dep
}
