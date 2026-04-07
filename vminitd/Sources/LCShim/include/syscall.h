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

// The below fall into two main categories:
// 1. Aren't exposed by Swifts glibc modulemap.
// 2. Don't have syscall wrappers/definitions in glibc/musl.

#ifndef __SYSCALL_H
#define __SYSCALL_H

#include <sys/types.h>
#include <sys/vfs.h>

// CLONE_* flags
#ifndef CLONE_NEWNS
#define CLONE_NEWNS     0x00020000
#endif
#ifndef CLONE_NEWCGROUP
#define CLONE_NEWCGROUP 0x02000000
#endif
#ifndef CLONE_NEWUTS
#define CLONE_NEWUTS    0x04000000
#endif
#ifndef CLONE_NEWIPC
#define CLONE_NEWIPC    0x08000000
#endif
#ifndef CLONE_NEWUSER
#define CLONE_NEWUSER   0x10000000
#endif
#ifndef CLONE_NEWPID
#define CLONE_NEWPID    0x20000000
#endif

extern int setns(int fd, int nstype);
extern int unshare(int flags);
extern int dup3(int oldfd, int newfd, int flags);
extern int execvpe(const char *file, char *const argv[], char *const envp[]);
extern int unlockpt(int fd);
extern char *ptsname(int fd);

// splice(2) and flags.
extern ssize_t splice(int fd_in, off_t *off_in, int fd_out, off_t *off_out,
                      size_t len, unsigned int flags);
#ifndef SPLICE_F_MOVE
#define SPLICE_F_MOVE    1
#endif
#ifndef SPLICE_F_NONBLOCK
#define SPLICE_F_NONBLOCK 2
#endif

// RLIMIT constants as plain integers. On glibc these are __rlimit_resource
// enum values which can't be used as Int32 in Swift.
#define CZ_RLIMIT_CPU        0
#define CZ_RLIMIT_FSIZE      1
#define CZ_RLIMIT_DATA       2
#define CZ_RLIMIT_STACK      3
#define CZ_RLIMIT_CORE       4
#define CZ_RLIMIT_RSS        5
#define CZ_RLIMIT_NPROC      6
#define CZ_RLIMIT_NOFILE     7
#define CZ_RLIMIT_MEMLOCK    8
#define CZ_RLIMIT_AS         9
#define CZ_RLIMIT_LOCKS      10
#define CZ_RLIMIT_SIGPENDING 11
#define CZ_RLIMIT_MSGQUEUE   12
#define CZ_RLIMIT_NICE       13
#define CZ_RLIMIT_RTPRIO     14
#define CZ_RLIMIT_RTTIME     15

// setrlimit wrapper that accepts plain int for the resource parameter,
// avoiding glibc's __rlimit_resource enum type mismatch in Swift.
int CZ_setrlimit(int resource, unsigned long long soft, unsigned long long hard);

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

#endif
