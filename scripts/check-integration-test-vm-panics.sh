#!/bin/bash
# Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

# Script to scan the VM boot logs from the integration tests for kernel panics.
# Looks for common kernel panic messages like "attempted to kill init" or "Kernel panic".

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$GIT_ROOT" ]; then
    echo "Error: Not in a git repository"
    exit 1
fi

BOOT_LOGS_DIR="$GIT_ROOT/bin/integration-bootlogs"

if [ ! -d "$BOOT_LOGS_DIR" ]; then
    echo "Error: Boot logs directory not found: $BOOT_LOGS_DIR"
    exit 1
fi

echo "Scanning boot logs in: $BOOT_LOGS_DIR"
echo "========================================"
echo ""

PANIC_FOUND=0

for logfile in "$BOOT_LOGS_DIR"/*; do
    if [ -f "$logfile" ]; then
        if grep -qi "attempted to kill init\|Kernel panic\|end Kernel panic\|Attempted to kill the idle task\|Oops:" "$logfile"; then
            echo "🚨 PANIC DETECTED in: $(basename "$logfile")"
            echo "---"
            grep -i -B 5 -A 10 "attempted to kill init\|Kernel panic\|end Kernel panic\|Attempted to kill the idle task\|Oops:" "$logfile" | head -30
            echo ""
            echo "========================================"
            echo ""
            PANIC_FOUND=1
        fi
    fi
done

if [ $PANIC_FOUND -eq 0 ]; then
    echo "✅ No kernel panics detected in boot logs"
else
    echo "❌ Found kernel panics - Virtual machine(s) crashed during integration tests"
fi

exit $PANIC_FOUND
