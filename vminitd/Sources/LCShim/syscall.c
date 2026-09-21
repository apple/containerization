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

int CZ_statfs(const char *path, CZ_Statfs *out) {
  struct statfs s;
  if (statfs(path, &s) != 0) {
    return -1;
  }
  out->f_type = (long long)s.f_type;
  out->f_bsize = (unsigned long long)s.f_bsize;
  out->f_blocks = (unsigned long long)s.f_blocks;
  out->f_bfree = (unsigned long long)s.f_bfree;
  out->f_bavail = (unsigned long long)s.f_bavail;
  out->f_files = (unsigned long long)s.f_files;
  out->f_ffree = (unsigned long long)s.f_ffree;
  out->f_fsid = ((long long)s.f_fsid.__val[0] << 32) |
                (unsigned int)s.f_fsid.__val[1];
  out->f_namelen = (unsigned long long)s.f_namelen;
  out->f_frsize = (unsigned long long)s.f_frsize;
  out->f_flags = (unsigned long long)s.f_flags;
  return 0;
}
#endif
