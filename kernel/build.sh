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

set -e

mkdir -p /kbuild
tar -xf /kernel/source.tar.xz -C /kbuild --strip-components=1
cp /kernel/config-arm64 /kbuild/.config

(
  cd /kbuild
  make olddefconfig && \
    make -j$((`nproc`-1)) && \
    cp arch/arm64/boot/Image /kernel/vmlinux
)
