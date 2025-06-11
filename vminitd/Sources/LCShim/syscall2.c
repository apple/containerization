/*
 * Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

#include "syscall2.h"

int syscall2(long number, void *arg1, void *arg2) {
  return syscall(number, arg1, arg2);
}

int set_sub_reaper() { return prctl(PR_SET_CHILD_SUBREAPER, 1); }
