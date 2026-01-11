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

#include "socket_helpers.h"

struct cmsghdr* CZ_CMSG_FIRSTHDR(struct msghdr *msg) {
    return CMSG_FIRSTHDR(msg);
}

void* CZ_CMSG_DATA(struct cmsghdr *cmsg) {
    return CMSG_DATA(cmsg);
}

size_t CZ_CMSG_SPACE(size_t length) {
    return CMSG_SPACE(length);
}

size_t CZ_CMSG_LEN(size_t length) {
    return CMSG_LEN(length);
}
