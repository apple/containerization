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

#ifndef __SYSCALL_H
#define __SYSCALL_H

#include <sys/types.h>

int CZ_pivot_root(const char *new_root, const char *put_old);

int CZ_set_sub_reaper();

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

int CZ_pidfd_open(pid_t pid, unsigned int flags);

#ifndef SYS_pidfd_getfd
#define SYS_pidfd_getfd 438
#endif

int CZ_pidfd_getfd(int pidfd, int targetfd, unsigned int flags);

int CZ_prctl_set_no_new_privs();

struct CZ_sock_filter {
  unsigned short code;
  unsigned char jt;
  unsigned char jf;
  unsigned int k;
};

struct CZ_sock_fprog {
  unsigned short len;
  struct CZ_sock_filter *filter;
};

int CZ_seccomp_set_mode_filter(unsigned int flags, struct CZ_sock_fprog *prog);

#endif
