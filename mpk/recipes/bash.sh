# GNU bash; same feature flags as compile_bash.sh
RUNTIME_DEPS=(coreutils)
recipe_build() {
  autotools_touch
  mpk_configure --without-bash-malloc --disable-nls --disable-profiling --disable-job-control
  make -j"$JOBS"
  stage_bin bash /bin/bash
  stage_bin bash /bin/sh
}
recipe_smoke() {
  smoke version "GNU bash" -- /bin/bash --version
  smoke arithmetic "42" -- /bin/bash -c 'echo $((6*7))'
  smoke loop "1 2 3" -- /bin/bash -c 'for i in 1 2 3; do printf "%s " $i; done'
  smoke command-substitution "sub-ok" -- /bin/bash -c 'x=$(echo sub-ok); echo $x'
  smoke subshell-fork "child" -- /bin/bash -c '(echo child); wait'
  smoke pipeline-builtins "HELLO" -- /bin/bash -c 'echo hello | { read l; echo ${l^^}; }'
  smoke exec-external "mpk-cat" -- /bin/bash -c 'echo mpk-cat | /bin/cat'
  smoke nested-bash "nested" -- /bin/bash -c '/bin/bash -c "echo nested"'
  smoke exit-status "" --exit 3 -- /bin/bash -c 'exit 3'
}
