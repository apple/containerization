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

#if defined(__linux__)

#include "cz_tap.h"

#include <errno.h>
#include <fcntl.h>
#include <net/if.h>     /* struct ifreq, IFNAMSIZ */
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/*
 * Avoid <linux/if_tun.h> — the Static Linux SDK (musl) used to cross-compile
 * vminitd ships <net/if.h> from musl but not the linux kernel UAPI headers.
 * The TUN ioctl number and flags are stable Linux ABI; redeclare locally.
 *
 * TUNSETIFF = _IOW('T', 202, int):
 *   dir=IOC_WRITE(1)<<30 | size(4)<<16 | type('T'=0x54)<<8 | nr(202=0xCA)
 *   = 0x400454CA
 * Architecture-independent (Linux's ioctl encoding is the same on x86/arm).
 */
#ifndef TUNSETIFF
#define TUNSETIFF 0x400454CAu
#endif
#ifndef IFF_TAP
#define IFF_TAP 0x0002
#endif
#ifndef IFF_NO_PI
#define IFF_NO_PI 0x1000
#endif

int cz_tap_create(const char *requested_name, char *out_name, size_t out_name_len) {
    if (out_name == NULL || out_name_len < IFNAMSIZ) {
        return -EINVAL;
    }

    int fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        return -errno;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    if (requested_name != NULL && requested_name[0] != '\0') {
        strncpy(ifr.ifr_name, requested_name, IFNAMSIZ - 1);
    }

    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        int saved = errno;
        close(fd);
        return -saved;
    }

    /* Copy out the resolved name. ifr.ifr_name is always NUL-terminated
     * within IFNAMSIZ by the kernel. */
    memset(out_name, 0, out_name_len);
    strncpy(out_name, ifr.ifr_name, IFNAMSIZ - 1);
    return fd;
}

#endif /* __linux__ */
