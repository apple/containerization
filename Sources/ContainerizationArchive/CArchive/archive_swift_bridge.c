/*
 * Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "archive_bridge.h"
#include <zstd.h>
#include <stdlib.h>
#include <unistd.h>

void archive_set_error_wrapper(struct archive *a, int error_number, const char *error_string) {
    archive_set_error(a, error_number, "%s", error_string);
}

int zstd_decompress_fd(int src_fd, int dst_fd) {
    ZSTD_DStream *dstream = ZSTD_createDStream();
    if (!dstream) return 1;

    size_t init_result = ZSTD_initDStream(dstream);
    if (ZSTD_isError(init_result)) {
        ZSTD_freeDStream(dstream);
        return 1;
    }

    size_t in_size = ZSTD_DStreamInSize();
    size_t out_size = ZSTD_DStreamOutSize();
    void *in_buf = malloc(in_size);
    void *out_buf = malloc(out_size);
    if (!in_buf || !out_buf) {
        free(in_buf);
        free(out_buf);
        ZSTD_freeDStream(dstream);
        return 1;
    }

    int rc = 0;
    ssize_t bytes_read;
    while ((bytes_read = read(src_fd, in_buf, in_size)) > 0) {
        ZSTD_inBuffer input = { in_buf, (size_t)bytes_read, 0 };
        while (input.pos < input.size) {
            ZSTD_outBuffer output = { out_buf, out_size, 0 };
            size_t result = ZSTD_decompressStream(dstream, &output, &input);
            if (ZSTD_isError(result)) { rc = 1; goto done; }
            if (output.pos > 0) {
                ssize_t written = write(dst_fd, out_buf, output.pos);
                if (written != (ssize_t)output.pos) { rc = 1; goto done; }
            }
        }
    }
    if (bytes_read < 0) rc = 1;

done:
    free(in_buf);
    free(out_buf);
    ZSTD_freeDStream(dstream);
    return rc;
}
