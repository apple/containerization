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
void* CZ_CMSG_DATA(struct cmsghdr *cmsg);
size_t CZ_CMSG_SPACE(size_t length);
size_t CZ_CMSG_LEN(size_t length);

// Receives exactly one SCM_RIGHTS descriptor and sets FD_CLOEXEC before returning it.
// On failure, it returns -1 and closes the descriptors in each well-formed control
// record; parsing stops at a malformed record. errno is one of:
// - a recvmsg or fcntl error
// - EMSGSIZE for truncated control data, usually from descriptor exhaustion
// - EPROTO for other invalid control data
// - ENODATA for ordinary EOF
// The caller owns the result and handles readiness and EINTR.
int CZ_receive_fd(int socket_fd);

// Linux-only accept4(2) with SOCK_CLOEXEC; glibc declares accept4 only under _GNU_SOURCE.
int CZ_accept_cloexec(int socket_fd);

#endif /* socket_helpers_h */
