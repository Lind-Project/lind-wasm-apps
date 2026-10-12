#include <config.h>
#include <stdio.h>
extern const char *__freadptr (FILE *, size_t *);
const char *freadptr (FILE *fp, size_t *sizep) { return __freadptr (fp, sizep); }
