/*
 * Copyright © 2026 Apple Inc. and the Containerization project authors.
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

#include "version.h"

#ifndef GIT_COMMIT
#define GIT_COMMIT "unspecified"
#endif

#ifndef GIT_TAG
#define GIT_TAG ""
#endif

#ifndef BUILD_TIME
#define BUILD_TIME "unspecified"
#endif

const char* CZ_get_git_commit(void) {
    return GIT_COMMIT;
}

const char* CZ_get_git_tag(void) {
    return GIT_TAG;
}

const char* CZ_get_build_time(void) {
    return BUILD_TIME;
}
