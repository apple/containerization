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

#if defined(__linux__) || defined(__APPLE__)

#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif

#include "exec_command.h"

#ifndef SYS_close_range
#define SYS_close_range 436
#endif

#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC 0x4
#endif

static int mark_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);

    if (flags == -1) return flags;
    if (flags & FD_CLOEXEC) return 0;

    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int cloexec_from(int min_fd) {
#if defined(__linux__)
    // First try close_range.
    long ret = syscall(SYS_close_range, min_fd, ~0U, CLOSE_RANGE_CLOEXEC);
    if (ret == 0) {
      return 0;
    }
    const char* dirpath = "/proc/self/fd";
#elif defined(__APPLE__)
    const char* dirpath = "/dev/fd";
#endif
    DIR *dp = opendir(dirpath);
    if (!dp) return -1;

    int dp_fd = dirfd(dp);
    struct dirent *de;

    while ((de = readdir(dp))) {
      if (de->d_name[0] == '.') continue;

      char *end;
      long val = strtol(de->d_name, &end, 10);
      if (*end || val < 0 || val > INT_MAX) continue;

      int fd = (int)val;
      if (fd < min_fd || fd == dp_fd) continue;

      int ret = mark_cloexec(fd);
      if (ret != 0) {
        return ret;
      }
    }
    close(dp_fd);
    closedir(dp);
    return 0;
}

void exec_command_attrs_init(struct exec_command_attrs *attrs) {
  attrs->setpgid = 0;
  attrs->pgid = 0;
  attrs->setsid = 0;
  attrs->setctty = 0;
  attrs->ctty = 0;
  attrs->mask = 0;
  attrs->uid = -1;
  attrs->gid = -1;
  attrs->pdeathSignal = 0;
}

static void child_handler(const int sync_pipes[2], const char *executable,
                          char *const args[], char *const environment[],
                          const int file_handles[], const int file_handle_count,
                          const char *cwd, const sigset_t old_mask,
                          const struct exec_command_attrs attrs) {
  int i = 0;
  int err = 0;
  int fd_index = 0;
  int fd_table[file_handle_count];
  struct rlimit limits = {0};
  int syncfd = sync_pipes[1];
  struct sigaction action = {0};

  // closing our parent's side of the pipe
  if (close(sync_pipes[0]) < 0) {
    goto fail;
  }

  // clear sighandlers
  action.sa_flags = 0;
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  for (i = 0; i < NSIG; i++) {
    sigaction(i, &action, 0);
  }

  sigset_t local_mask;
  sigemptyset(&local_mask);
  if (pthread_sigmask(SIG_SETMASK, &local_mask, NULL) < 0) {
    goto fail;
  }

  // start shuffling fds.
  // look at all the file handles and find the highest one,
  // use that for our pipe,
  //
  // Then, we need to start dup2 the fds starting for the final process
  // at 0-n.
  // as an example we have this list of FDs that should be passed to the
  // process:
  //
  /*
   The index of this list is the final result that the new process expects.
   The values are open fds provided from the parent process.
   [0] == 12
   [1] == 7
   [2] == 9
   [3] == 0

   We also have a pipe to sync the child and parent so that adds an additional
   parameter to consider.

   So we start by finding the highest open fd in the list, then move our pipe to
   the next.

   i.e. fd12 is highest so move our pipe to fd13

   Now start moving all the fds above our pipe as we will need to start placing
   the fds in the child process into the right order. Make sure they are all
   marked cloexec.

   pipe == 13
   [0] == 12 dup2 14
   [1] == 7 dup2 15
   [2] == 9 dup2 16
   [3] == 0 dup2 17

   Now overwrite the fd table for the child with the current index.

   Make index == fd.

   pipe == 13
   [0] == 14 dup2 0
   [1] == 15 dup2 1
   [2] == 16 dup2 2
   [3] == 17 dup2 3

   Clear cloexec on this new fds.
   */

  // find the highest fd value in our list.
  for (i = 0; i < file_handle_count; i++) {
    if (file_handles[i] > fd_index) {
      fd_index = file_handles[i];
    }
    fd_table[i] = file_handles[i];
  }
  // now fd_index is == to the highest fd in our list of handles.
  // Increment it and set our pipe to it.
  fd_index++;

  if (syncfd != fd_index) {
    if (dup2(syncfd, fd_index) < 0) {
      goto fail;
    }
    if (close(syncfd) < 0) {
      goto fail;
    }
    syncfd = fd_index;
  }
  fd_index++;

  // make sure our syncfd retains its cloexec
  if (fcntl(syncfd, F_SETFD, FD_CLOEXEC) == -1) {
    goto fail;
  }

  // move the rest of the fds up above our index if they don't match the index.
  for (i = 0; i < file_handle_count; i++) {
    if (fd_table[i] == i) {
      continue;
    }
    if (dup2(fd_table[i], fd_index) < 0) {
      goto fail;
    }
    if (fcntl(fd_index, F_SETFD, FD_CLOEXEC) == -1) {
      goto fail;
    }
    fd_table[i] = fd_index;
    fd_index++;
  }

  // now create the child process's final fd table. where i == i
  for (i = 0; i < file_handle_count; i++) {
    if (fd_table[i] != i) {
      if (dup2(fd_table[i], i) < 0) {
        goto fail;
      }
    }
    // now fd[i] should == i
    // clear cloexec as this fd is where we want it.
    if (fcntl(i, F_SETFD, 0) == -1) {
      goto fail;
    }
  }

  if (attrs.setsid) {
    if (setsid() == -1) {
      goto fail;
    }
  }
  if (attrs.setpgid) {
    if (setpgid(0, attrs.pgid) < 0) {
      goto fail;
    }
  }

  if (attrs.setctty) {
    if (ioctl(attrs.ctty, TIOCSCTTY, 0)) {
      goto fail;
    }
  }

#if defined(__linux__)
  // Set parent death signal if specified
  if (attrs.pdeathSignal != 0) {
    if (prctl(PR_SET_PDEATHSIG, attrs.pdeathSignal) != 0) {
      goto fail;
    }
  }
#endif

  // close exec everything outside of our child's fd_table.
  if (cloexec_from(file_handle_count) != 0) {
    goto fail;
  }

  // set gid
  if (attrs.gid != -1) {
    if (setgid(attrs.gid) != 0) {
      goto fail;
    }
  }

  // set uid
  if (attrs.uid != -1) {
    if (setreuid(attrs.uid, attrs.uid) != 0) {
      goto fail;
    }
  }

  if (cwd != NULL) {
    if (chdir(cwd)) {
      goto fail;
    }
  }

  execve(executable, args, environment);
fail:
  err = errno;
  if (err) {
    // send our error to the parent
    while (write(syncfd, &err, sizeof(err)) < 0)
      ;
  }
  exit(127);
}

int exec_command(pid_t *result, const char *executable, char *const args[],
                 char *const envp[], const int file_handles[],
                 const int file_handle_count, const char *working_directory,
                 struct exec_command_attrs *attrs) {
  pid_t pid = 0;
  int err = 0;
  int sync_pipe[2];
  sigset_t old_mask;

  sigset_t all;
  sigfillset(&all);

  if (pipe(sync_pipe)) {
    goto fail;
  }

  if (pthread_sigmask(SIG_SETMASK, &all, &old_mask) < 0) {
    goto fail;
  }

  pid = fork();
  if (pid == -1) {
    close(sync_pipe[0]);
    close(sync_pipe[1]);
    goto fail;
  }

  if (pid == 0) {
    // hand off to child
    child_handler(sync_pipe, executable, args, envp, file_handles,
                  file_handle_count, working_directory, old_mask, *attrs);
    exit(EXIT_FAILURE);
  }

  // handle parent operations
  if (close(sync_pipe[1]) < 0) {
    goto fail;
  }

  // sync with our child process
  err = 0;
  ssize_t size = read(sync_pipe[0], &err, sizeof(err));
  // -- we didn't get an errno back
  if (size != sizeof(err)) {
    // will be used as return result
    err = 0;
  } else {
    // we did get an errno back from the child process and our
    // err var is set to that errno
    // lets set our errno and then reap the process
    errno = err;
    int status = 0;
    waitpid(pid, &status, 0);
    // lets continue our journey below
  }

  if (close(sync_pipe[0]) < 0) {
    goto fail;
  }
  if (err) {
    goto fail;
  }

  (*result) = pid;
  err = 0;
fail:
  if (pthread_sigmask(SIG_SETMASK, &old_mask, 0) < 0) {
    printf("restoring signal mask: %s\n", strerror(errno));
  }
  if (err) {
    printf("exec_command execve: %s\n", strerror(err));
    return -1;
  }
  return 0;
}

#endif