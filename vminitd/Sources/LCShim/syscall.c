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

#include <sys/prctl.h>
#include <sys/syscall.h>
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
