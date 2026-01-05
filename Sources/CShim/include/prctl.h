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

#ifndef __PRCTL_H
#define __PRCTL_H

#if defined(__linux__)

#include <sys/types.h>

// Capability management prctl wrappers
int CZ_prctl_set_keepcaps();
int CZ_prctl_clear_keepcaps();
int CZ_prctl_capbset_drop(unsigned int capability);
int CZ_prctl_cap_ambient_clear_all();
int CZ_prctl_cap_ambient_raise(unsigned int capability);

#endif

#endif
