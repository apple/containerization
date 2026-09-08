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

#ifndef __OPENAT2_H
#define __OPENAT2_H

#include <sys/types.h>

#ifndef RESOLVE_IN_ROOT
#define RESOLVE_IN_ROOT 0x10
#endif

struct cz_open_how {
  unsigned long long flags;
  unsigned long long mode;
  unsigned long long resolve;
};

/// openat2(2) wrapper. Musl does not provide openat2 so we invoke the syscall
/// directly. Requires Linux 5.6+.
int CZ_openat2(int dirfd, const char *pathname, struct cz_open_how *how,
               size_t size);

#endif
