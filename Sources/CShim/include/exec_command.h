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

#ifndef exec_command_h
#define exec_command_h

#if defined(__linux__) || defined(__APPLE__)

#include <sys/types.h>
#include <unistd.h>

struct exec_command_attrs {
  int setpgid;
  /// parent group id
  pid_t pgid;
  /// set the controlling terminal
  int setctty;
  /// controlling terminal fd
  int ctty;
  /// set the process as session leader
  int setsid;
  /// set the process user id
  uid_t uid;
  /// set the process group id
  gid_t gid;
  /// signal mask for the child process
  int mask;
  /// parent death signal (Linux only, 0 to disable)
  int pdeathSignal;
};

void exec_command_attrs_init(struct exec_command_attrs *attrs);

/// spawn a new child process with the provided attrs
int exec_command(pid_t *result, const char *executable, char *const argv[],
                 char *const envp[], const int file_handles[],
                 const int file_handle_count, const char *working_directory,
                 struct exec_command_attrs *attrs);

#endif /* defined(__linux__) || defined(__APPLE__) */
#endif /* exec_command_h */
