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

#if defined(__linux__)

#include <sys/prctl.h>
#include "prctl.h"

// Set keep caps to preserve capabilities across setuid()
int CZ_prctl_set_keepcaps() {
    return prctl(PR_SET_KEEPCAPS, 1, 0, 0, 0);
}

// Clear keep caps after user change
int CZ_prctl_clear_keepcaps() {
    return prctl(PR_SET_KEEPCAPS, 0, 0, 0, 0);
}

// Drop capability from bounding set
int CZ_prctl_capbset_drop(unsigned int capability) {
    return prctl(PR_CAPBSET_DROP, capability, 0, 0, 0);
}

// Clear all ambient capabilities
int CZ_prctl_cap_ambient_clear_all() {
    return prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
}

// Raise ambient capability
int CZ_prctl_cap_ambient_raise(unsigned int capability) {
    return prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, capability, 0, 0);
}

#endif
