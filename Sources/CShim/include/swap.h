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

#ifndef __SWAP_H
#define __SWAP_H

#if defined(__linux__)

// swapon(2) lives in <sys/swap.h>, which Swift's glibc modulemap does not
// carry, so it is reachable from Swift only through a wrapper.

// Discard the whole area when it is enabled, and each page as it is freed.
// These come from the same header, and SWAP_FLAG_DISCARD_PAGES has no UAPI
// header of its own at all, so every consumer declares it; see util-linux
// sys-utils/swapon.c.
#define CZ_SWAP_DISCARD 0x10000
#define CZ_SWAP_DISCARD_PAGES 0x40000

int CZ_swapon(const char *path, int flags);

#endif

#endif
