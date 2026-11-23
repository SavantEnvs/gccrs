/* libFuzzer harness for libiberty's simple-object readers (ELF, COFF,
   Mach-O, XCOFF), the code lto-plugin, collect2, lto-wrapper and the gccrs
   crate-metadata importer use to open object files and find their sections.
   The input is the object file; it is handed to the library as a file
   descriptor (an in-memory memfd), exactly like a file on disk.  */
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include "simple-object.h"

struct ctx {
  int fd;
  off_t size;
  unsigned long sum;
};

/* The section name is deliberately not read here: libiberty's own
   simple_object_find_section (find_one_section -> strcmp) reads it right
   after, the way lto-plugin/collect2 do, so a bad name table faults in a
   libiberty frame rather than in this callback.  */
static int section_cb(void *data, const char *name, off_t offset, off_t length) {
  struct ctx *c = (struct ctx *) data;
  (void) name;
  if (offset >= 0 && length > 0 && offset < c->size) {
    off_t n = length;
    if (n > c->size - offset)
      n = c->size - offset;
    char *buf = (char *) malloc((size_t) n);
    if (buf) {
      ssize_t r = pread(c->fd, buf, (size_t) n, offset);
      if (r > 0)
        c->sum += (unsigned char) buf[r - 1];
      free(buf);
    }
  }
  return 1; /* continue */
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  int fd = memfd_create("simple_object_fuzz", 0);
  if (fd < 0)
    return 0;
  size_t off = 0;
  while (off < size) {
    ssize_t w = write(fd, data + off, size - off);
    if (w <= 0) {
      close(fd);
      return 0;
    }
    off += (size_t) w;
  }

  const char *errmsg = NULL;
  int err = 0;
  simple_object_read *sobj = simple_object_start_read(fd, 0, NULL, &errmsg, &err);
  if (sobj) {
    struct ctx c = { fd, (off_t) size, 0 };
    simple_object_find_sections(sobj, section_cb, &c, &err);
    off_t so, sl;
    simple_object_find_section(sobj, ".rust_export", &so, &sl, &errmsg, &err);
    simple_object_find_section(sobj, ".gnu.lto_.opts", &so, &sl, &errmsg, &err);
    simple_object_attributes *attrs = simple_object_fetch_attributes(sobj, &errmsg, &err);
    if (attrs) {
      simple_object_attributes *attrs2 = simple_object_fetch_attributes(sobj, &errmsg, &err);
      if (attrs2) {
        simple_object_attributes_merge(attrs, attrs2, &err);
        simple_object_release_attributes(attrs2);
      }
      simple_object_release_attributes(attrs);
    }
    simple_object_release_read(sobj);
  }
  close(fd);
  return 0;
}
