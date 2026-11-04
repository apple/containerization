#!/bin/bash
# Copyright © 2026 Apple Inc. and the Containerization project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Checks that host proxy variables are forwarded into `make linux-image`
# and `linux_run`, and that an unset proxy does not emit flags or recurse.
# Does not build the dev image.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failures=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

trim() {
    printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'
}

# Drop every spelling, then let the caller set the case under test.
run_make() {
    env \
        -u HTTP_PROXY -u HTTPS_PROXY -u NO_PROXY -u ALL_PROXY -u all_proxy \
        -u http_proxy -u https_proxy -u no_proxy \
        "$@"
}

forwarding() {
    run_make "$@" make -s proxy-forwarding-args
}

expect_forwarding() {
    local label="$1"
    local expected_build="$2"
    local expected_run="$3"
    shift 3
    local out build run
    if ! out="$(forwarding "$@")"; then
        fail "$label: make proxy-forwarding-args failed"
        return
    fi
    build="$(printf '%s\n' "$out" | sed -n 's/^BUILD //p' | head -1)"
    run="$(printf '%s\n' "$out" | sed -n 's/^RUN //p' | head -1)"
    build="$(trim "$build")"
    run="$(trim "$run")"
    if [[ "$build" != "$expected_build" ]]; then
        fail "$label build
  expected: [$expected_build]
  actual:   [$build]"
    fi
    if [[ "$run" != "$expected_run" ]]; then
        fail "$label run
  expected: [$expected_run]
  actual:   [$run]"
    fi
}

quote_args() {
    # $1 is the make flag prefix: --build-arg or --env
    local prefix="$1"
    shift
    local out="" name value
    while [[ $# -gt 0 ]]; do
        name="$1"
        value="$2"
        shift 2
        out+="${out:+ }$prefix $name=\"$value\""
    done
    printf '%s' "$out"
}

# Both spellings unset must finish, and must not invent flags.
# `?=` between the two names used to recurse forever in this case.
expect_forwarding "unset" "" ""

expect_forwarding "uppercase HTTP_PROXY fills http_proxy" \
    "$(quote_args --build-arg HTTP_PROXY http://proxy.example:8080 http_proxy http://proxy.example:8080)" \
    "$(quote_args --env HTTP_PROXY http://proxy.example:8080 http_proxy http://proxy.example:8080)" \
    HTTP_PROXY=http://proxy.example:8080

expect_forwarding "lowercase http_proxy fills HTTP_PROXY" \
    "$(quote_args --build-arg HTTP_PROXY http://proxy.example:8080 http_proxy http://proxy.example:8080)" \
    "$(quote_args --env HTTP_PROXY http://proxy.example:8080 http_proxy http://proxy.example:8080)" \
    http_proxy=http://proxy.example:8080

expect_forwarding "explicit spellings are both kept" \
    "$(quote_args --build-arg HTTP_PROXY http://upper.example:8080 http_proxy http://lower.example:8081)" \
    "$(quote_args --env HTTP_PROXY http://upper.example:8080 http_proxy http://lower.example:8081)" \
    HTTP_PROXY=http://upper.example:8080 http_proxy=http://lower.example:8081

expect_forwarding "https only" \
    "$(quote_args --build-arg HTTPS_PROXY http://secure.example:8443 https_proxy http://secure.example:8443)" \
    "$(quote_args --env HTTPS_PROXY http://secure.example:8443 https_proxy http://secure.example:8443)" \
    HTTPS_PROXY=http://secure.example:8443

expect_forwarding "NO_PROXY keeps commas" \
    "$(quote_args --build-arg NO_PROXY 'localhost,127.0.0.1,.example.com' no_proxy 'localhost,127.0.0.1,.example.com')" \
    "$(quote_args --env NO_PROXY 'localhost,127.0.0.1,.example.com' no_proxy 'localhost,127.0.0.1,.example.com')" \
    NO_PROXY='localhost,127.0.0.1,.example.com'

expect_forwarding "empty HTTP_PROXY is omitted" "" "" HTTP_PROXY=

dockerfile="images/linux-dev/Dockerfile"
if grep -E -q '^ENV[[:space:]]+(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy)([[:space:]]|$)' "$dockerfile"; then
    fail "proxy values must stay ARG so they are not stored in the image"
fi
if ! awk '
    /^RUN / { if (!seen_arg) missing = 1; seen_run = 1 }
    /^ARG HTTP_PROXY$/ { http = 1; seen_arg = 1; if (seen_run) late = 1 }
    /^ARG HTTPS_PROXY$/ { https = 1 }
    /^ARG NO_PROXY$/ { no = 1 }
    /^ARG http_proxy=\$\{HTTP_PROXY\}$/ { http_lc = 1 }
    /^ARG https_proxy=\$\{HTTPS_PROXY\}$/ { https_lc = 1 }
    /^ARG no_proxy=\$\{NO_PROXY\}$/ { no_lc = 1 }
    END { exit !(http && https && no && http_lc && https_lc && no_lc && !late && !missing) }
' "$dockerfile"; then
    fail "Dockerfile proxy ARGs must default the lowercase names and come before the first RUN"
fi

if [[ "$(uname -s)" == Darwin ]]; then
    image="$(run_make HTTP_PROXY=http://proxy.example:8080 make -n linux-image)"
    if [[ "$image" != *'--build-arg HTTP_PROXY="http://proxy.example:8080"'* ]] \
        || [[ "$image" != *'--build-arg http_proxy="http://proxy.example:8080"'* ]]; then
        fail "linux-image dry run did not forward HTTP_PROXY onto both spellings"
    fi
    image_unset="$(run_make make -n linux-image)"
    if [[ "$image_unset" == *'--build-arg HTTP_PROXY'* ]] \
        || [[ "$image_unset" == *'--build-arg http_proxy'* ]] \
        || [[ "$image_unset" == *'--build-arg HTTPS_PROXY'* ]] \
        || [[ "$image_unset" == *'--build-arg NO_PROXY'* ]]; then
        fail "linux-image dry run emitted a proxy build arg when none were set"
    fi
    run_out="$(run_make HTTP_PROXY=http://proxy.example:8080 make -n linux-build)"
    if [[ "$run_out" != *'--env HTTP_PROXY="http://proxy.example:8080"'* ]] \
        || [[ "$run_out" != *'--env http_proxy="http://proxy.example:8080"'* ]]; then
        fail "linux-build dry run did not forward HTTP_PROXY into container run"
    fi
fi

if [[ "$failures" -ne 0 ]]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi

printf 'proxy forwarding checks passed\n'
