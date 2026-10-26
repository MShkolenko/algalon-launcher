#pragma once
#include <stddef.h>
#include <stdint.h>

// Verify the complete bounded ZIP entry before any filesystem extraction. Optional output is for links.
int archive_check_entry(const unsigned char *data, size_t length, uint64_t expected,
                        uint32_t checksum, uint16_t method, unsigned char *output, size_t capacity);
