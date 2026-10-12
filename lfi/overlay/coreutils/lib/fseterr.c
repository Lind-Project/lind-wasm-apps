/* gnulib's fseterr/freadahead/freadptr for musl, which exports the primitives
   (the coreutils gnulib snapshot predates musl support). */
#include <config.h>
#include <stdio.h>
extern void __fseterr (FILE *);
void fseterr (FILE *fp) { __fseterr (fp); }
