//

#pragma once

#include "archive.h"
#include <stdint.h>

void archive_set_error_wrapper(struct archive *a, int error_number, const char *error_string);

/// Decompress a zstd-compressed file at \p src_fd into \p dst_fd.
/// Returns 0 on success, or a non-zero error code on failure.
int zstd_decompress_fd(int src_fd, int dst_fd);
