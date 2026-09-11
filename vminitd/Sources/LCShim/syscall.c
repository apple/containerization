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

#ifdef __linux__
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

#include "syscall.h"

int CZ_pivot_root(const char *new_root, const char *put_old) {
  return syscall(SYS_pivot_root, new_root, put_old);
}

int CZ_set_sub_reaper() { return prctl(PR_SET_CHILD_SUBREAPER, 1); }

int CZ_pidfd_open(pid_t pid, unsigned int flags) {
  // Musl doesn't have pidfd_open.
  return syscall(SYS_pidfd_open, pid, flags);
}

int CZ_pidfd_getfd(int pidfd, int targetfd, unsigned int flags) {
  // Musl doesn't have pidfd_getfd.
  return syscall(SYS_pidfd_getfd, pidfd, targetfd, flags);
}

#ifndef SYS_clone3
#define SYS_clone3 435
#endif

#ifndef CLONE_INTO_CGROUP
#define CLONE_INTO_CGROUP 0x200000000ULL
#endif

// Keep this layout in sync with Linux's struct clone_args. Defining the
// syscall ABI locally avoids relying on a particular userspace header age.
struct cz_clone_args {
  uint64_t flags;
  uint64_t pidfd;
  uint64_t child_tid;
  uint64_t parent_tid;
  uint64_t exit_signal;
  uint64_t stack;
  uint64_t stack_size;
  uint64_t tls;
  uint64_t set_tid;
  uint64_t set_tid_size;
  uint64_t cgroup;
};

pid_t CZ_clone_into_cgroup(int cgroup_fd) {
  struct cz_clone_args args = {0};
  args.flags = CLONE_INTO_CGROUP;
  args.exit_signal = SIGCHLD;
  args.cgroup = (uint64_t)cgroup_fd;
  return (pid_t)syscall(SYS_clone3, &args, sizeof(args));
}

int CZ_prctl_set_no_new_privs() {
  return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}

int CZ_setrlimit(int resource, unsigned long long soft,
                 unsigned long long hard) {
  struct rlimit limit;
  limit.rlim_cur = (rlim_t)soft;
  limit.rlim_max = (rlim_t)hard;
  return setrlimit(resource, &limit);
}
#endif
