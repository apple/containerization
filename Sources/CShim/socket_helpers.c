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

#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "socket_helpers.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

// Linux UAPI value; older libc headers may not expose it yet.
#if defined(__linux__) && !defined(SCM_PIDFD)
#define SCM_PIDFD 0x04
#endif

void* CZ_CMSG_DATA(struct cmsghdr *cmsg) {
    return CMSG_DATA(cmsg);
}

size_t CZ_CMSG_SPACE(size_t length) {
    return CMSG_SPACE(length);
}

size_t CZ_CMSG_LEN(size_t length) {
    return CMSG_LEN(length);
}

int CZ_receive_fd(int socket_fd) {
    // XNU installs every right before copying out control data, so truncation would
    // hide installed descriptors. Its rights are bounded by MCLBYTES of internal
    // pointers (254 rights, 1028 bytes copied out); Linux allows 253 rights plus
    // credential and pidfd records. 4 KiB holds the largest set either kernel delivers.
    union {
        struct cmsghdr alignment;
        unsigned char bytes[4096];
    } control;
    unsigned char byte;
    struct iovec iov = { .iov_base = &byte, .iov_len = sizeof(byte) };
    struct msghdr message = {0};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = sizeof(control.bytes);

    int flags = 0;
#ifdef __linux__
    flags = MSG_CMSG_CLOEXEC;
#endif
    ssize_t count = recvmsg(socket_fd, &message, flags);
    if (count < 0) {
        return -1;
    }

    int received = -1;
    size_t offset = 0;
    size_t length = message.msg_controllen;
    int invalid = (message.msg_flags & MSG_CTRUNC) != 0;
    if (length > sizeof(control.bytes)) {
        length = sizeof(control.bytes);
        invalid = 1;
    }
    while (length - offset >= sizeof(struct cmsghdr)) {
        struct cmsghdr header;
        memcpy(&header, control.bytes + offset, sizeof(header));
        size_t header_length = CMSG_LEN(0);
        if (header.cmsg_len < header_length || header.cmsg_len > length - offset) {
            // A malformed length cannot establish which bytes are descriptors.
            invalid = 1;
            break;
        }
        size_t payload_length = header.cmsg_len - header_length;
        if (header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS) {
            if (payload_length == 0 || payload_length % sizeof(int) != 0) {
                invalid = 1;
            }
            for (size_t i = 0; i + sizeof(int) <= payload_length; i += sizeof(int)) {
                int fd;
                memcpy(&fd, control.bytes + offset + header_length + i, sizeof(fd));
                if (fd < 0) {
                    invalid = 1;
                } else if (received < 0) {
                    received = fd;
                } else {
                    // Never retry close: the descriptor number may already be reused.
                    close(fd);
                    invalid = 1;
                }
            }
#ifdef __linux__
        } else if (header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_PIDFD) {
            // SO_PASSPIDFD installs a descriptor even though this record is rejected.
            invalid = 1;
            if (payload_length >= sizeof(int)) {
                int fd;
                memcpy(&fd, control.bytes + offset + header_length, sizeof(fd));
                if (fd >= 0) {
                    close(fd);
                }
            }
#endif
        } else {
            invalid = 1;
        }
        size_t stride = CMSG_SPACE(payload_length);
        if (stride > length - offset) {
            // Native trailing alignment padding may be omitted.
            break;
        }
        offset += stride;
    }

    int error = (message.msg_flags & MSG_CTRUNC) != 0 ? EMSGSIZE : EPROTO;
    if (!invalid && received >= 0) {
#ifndef __linux__
        int descriptor_flags = fcntl(received, F_GETFD);
        if (descriptor_flags >= 0 && fcntl(received, F_SETFD, descriptor_flags | FD_CLOEXEC) >= 0) {
            return received;
        }
        error = errno;
#else
        return received;
#endif
    } else if (!invalid && received < 0 && count == 0) {
        error = ENODATA;
    }
    if (received >= 0) {
        close(received);
    }
    errno = error;
    return -1;
}

#if defined(__linux__)
int CZ_accept_cloexec(int socket_fd) {
    return accept4(socket_fd, NULL, NULL, SOCK_CLOEXEC);
}
#endif
