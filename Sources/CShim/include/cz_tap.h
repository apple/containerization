/*
 * Copyright © 2026 Apple Inc. and the Containerization project authors.
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

#ifndef __CZ_TAP_H
#define __CZ_TAP_H

#include <stddef.h>

/*
 * Open /dev/net/tun, ioctl(TUNSETIFF) with IFF_TAP|IFF_NO_PI, and write the
 * resolved interface name into `out_name` (must be at least 16 bytes).
 *
 * If `requested_name` is non-NULL and non-empty, it is the desired name; the
 * kernel may rename it on collision (rare). If NULL or empty, the kernel
 * picks a name like "tap%d".
 *
 * Returns the open fd on success, -errno on failure.
 *
 * Linux-only — the implementation in cz_tap.c is gated on __linux__. The
 * declaration is left unconditional so Swift's clang importer can see it
 * regardless of whose target's preprocessor defines reach the modulemap.
 * On non-Linux targets the symbol is not provided; do not call.
 */
int cz_tap_create(const char *requested_name, char *out_name, size_t out_name_len);

#endif /* __CZ_TAP_H */
