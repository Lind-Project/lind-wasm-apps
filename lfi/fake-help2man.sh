#!/bin/sh
# Stand-in for help2man: the real one runs the built program, which cannot run
# on the build machine. Man pages are not part of what is being built.
for a in "$@"; do case $a in --output=*) : > "${a#--output=}" ;; esac; done
exit 0
