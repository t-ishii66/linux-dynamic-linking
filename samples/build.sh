#!/bin/sh
# Build the sample on a Linux x86_64 host (or inside a Linux container).
# Run from this directory:    sh build.sh
set -eu

# 1. Build the shared library.
#    -shared : produce a shared object (.so)
#    -fPIC   : position-independent code (required for .so)
gcc -shared -fPIC -o libmylib.so mylib.c

# 2. Build the main executable as a PIE (ET_DYN).
#    -fPIE -pie           : force position-independent executable
#                           (the whole docs series assumes ET_DYN; not all
#                           distros default to PIE)
#    -L.                  : look for libraries in the current dir
#    -lmylib              : link against libmylib.so
#    -Wl,-rpath,'$ORIGIN' : at runtime, look for libmylib.so next to main
#    -Wl,-z,lazy          : enable the lazy-binding path used in the docs
gcc -fPIE -pie -o main main.c -L. -lmylib \
    -Wl,-rpath,'$ORIGIN' -Wl,-z,lazy

echo "Built: libmylib.so, main"
echo "Run:   ./main ; echo \$?    # should print 5"
