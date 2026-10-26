#include "keystore.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void) {
  const size_t boundary = 4u << 20, size = boundary + 4096;
  unsigned char *region = mmap(NULL, size, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(region != MAP_FAILED);
  unsigned char *table = region + boundary - 16;
  unsigned char known[KS_COUNT * KS_KEYLEN], flags[KS_COUNT], replacement[KS_KEYLEN];
  memset(replacement, 0xa5, sizeof(replacement));
  for (size_t e = 0; e < KS_COUNT; ++e) {
    flags[e] = e % 2;
    table[e * KS_ENTRY] = e + 1;
    for (size_t i = 0; i < KS_KEYLEN; ++i)
      known[e * KS_KEYLEN + i] = (e * 31 + i * 7) % 251;
    memcpy(table + e * KS_ENTRY + 4, known + e * KS_KEYLEN, KS_KEYLEN);
    table[e * KS_ENTRY + 36] = flags[e];
  }
  ks_result result;
  ks_scan_and_patch(mach_task_self(), known, flags, replacement, 8, &result);
  assert(result.patched_now >= 1 && result.write_errors == 0);
  for (size_t e = 0; e < KS_COUNT; ++e) {
    const unsigned char *entry = table + e * KS_ENTRY;
    assert(entry[0] == e + 1 && entry[1] == 0 && entry[2] == 0 && entry[3] == 0);
    assert(memcmp(entry + 4, e == 7 ? replacement : known + e * KS_KEYLEN, KS_KEYLEN) == 0);
    assert(entry[36] == flags[e] && entry[37] == 0 && entry[38] == 0 && entry[39] == 0);
  }
  puts("PASS: Mach scanner patches only group 8 across a chunk boundary");
  ks_scan_and_patch(mach_task_self(), known, flags, replacement, 8, &result);
  assert(result.already_patched >= 1 && result.write_errors == 0);
  puts("PASS: Mach scanner recognizes an already patched table");
  memcpy(table + 7 * KS_ENTRY + 4, known + 7 * KS_KEYLEN, KS_KEYLEN);
  table[38] = 1;
  ks_scan_and_patch(mach_task_self(), known, flags, replacement, 8, &result);
  assert(memcmp(table + 7 * KS_ENTRY + 4, known + 7 * KS_KEYLEN, KS_KEYLEN) == 0);
  puts("PASS: Mach scanner refuses a malformed table");
  table[38] = 0;
  memmove(table + 1, table, KS_ENTRY * KS_COUNT);
  ks_scan_and_patch(mach_task_self(), known, flags, replacement, 8, &result);
  assert(memcmp(table + 1 + 7 * KS_ENTRY + 4, known + 7 * KS_KEYLEN, KS_KEYLEN) == 0);
  puts("PASS: Mach scanner ignores unaligned tables");
  assert(munmap(region, size) == 0);
  return 0;
}
