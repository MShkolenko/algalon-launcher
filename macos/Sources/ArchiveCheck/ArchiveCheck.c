#include "ArchiveCheck.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

int archive_check_entry(const unsigned char *data, size_t length, uint64_t expected,
                        uint32_t checksum, uint16_t method, unsigned char *output, size_t capacity) {
  if ((!data && length) || length > 52428800 || expected > 262144000 || length > UINT_MAX
      || (output && expected > capacity)) return 0;
  uLong crc = crc32(0, Z_NULL, 0);
  if (method == 0) {
    if (length != expected) return 0;
    crc = crc32(crc, data, (uInt)length);
    if (output && length) memcpy(output, data, length);
    return crc == checksum;
  }
  if (method != 8) return 0;
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
  stream.next_in = (Bytef *)data;
  stream.avail_in = (uInt)length;
  int status = Z_OK, valid = 0;
  unsigned char buffer[16384];
  size_t written = 0;
  while (status == Z_OK) {
    stream.next_out = buffer;
    stream.avail_out = sizeof(buffer);
    status = inflate(&stream, Z_NO_FLUSH);
    size_t count = sizeof(buffer) - stream.avail_out;
    if (stream.total_out > expected || (status != Z_OK && status != Z_STREAM_END)) break;
    crc = crc32(crc, buffer, (uInt)count);
    if (output) {
      if (count > capacity - written) break;
      memcpy(output + written, buffer, count);
      written += count;
    }
    if (status == Z_STREAM_END) {
      valid = stream.total_in == length && stream.total_out == expected && crc == checksum;
    }
  }
  inflateEnd(&stream);
  return valid;
}
