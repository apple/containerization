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

#ifndef socket_helpers_h
#define socket_helpers_h

#include <sys/socket.h>
#include <stdint.h>

// Helper functions to access CMSG macros from Swift
struct cmsghdr* CZ_CMSG_FIRSTHDR(struct msghdr *msg);
void* CZ_CMSG_DATA(struct cmsghdr *cmsg);
size_t CZ_CMSG_SPACE(size_t length);
size_t CZ_CMSG_LEN(size_t length);

#endif /* socket_helpers_h */
