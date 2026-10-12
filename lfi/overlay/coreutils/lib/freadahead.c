#include <config.h>
#include <stdio.h>
extern size_t __freadahead (FILE *);
size_t freadahead (FILE *fp) { return __freadahead (fp); }
