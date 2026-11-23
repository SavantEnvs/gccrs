/* libFuzzer harness for libiberty's demanglers (C++ Itanium, GNU v3 auto
   style, Rust legacy/v0, D, Java/GCJ) through the public demangle.h API --
   the code c++filt, binutils, gdb and the GCC Rust front end use on symbol
   names read from object files.  */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "demangle.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  char *s = (char *) malloc(size + 1);
  if (!s)
    return 0;
  memcpy(s, data, size);
  s[size] = '\0'; /* the demanglers take NUL-terminated strings */

  static const int opts[] = {
    DMGL_PARAMS | DMGL_ANSI | DMGL_TYPES,
    DMGL_PARAMS | DMGL_ANSI | DMGL_VERBOSE | DMGL_RET_POSTFIX,
    DMGL_NO_OPTS,
  };
  for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) {
    free(cplus_demangle(s, opts[i] | DMGL_AUTO));
  }
  free(cplus_demangle(s, DMGL_PARAMS | DMGL_ANSI | DMGL_GNU_V3));
  free(cplus_demangle(s, DMGL_PARAMS | DMGL_ANSI | DMGL_RUST));
  free(cplus_demangle(s, DMGL_PARAMS | DMGL_ANSI | DMGL_DLANG));
  free(cplus_demangle_v3(s, DMGL_PARAMS | DMGL_ANSI | DMGL_TYPES));
  free(java_demangle_v3(s));
  free(rust_demangle(s, DMGL_PARAMS | DMGL_VERBOSE));
  free(dlang_demangle(s, DMGL_PARAMS));
  free(s);
  return 0;
}
