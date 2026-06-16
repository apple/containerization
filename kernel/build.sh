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

TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"

case "${TARGET_ARCH}" in
  aarch64|arm64)
    CONFIG=config-arm64
    KARCH=arm64
    CROSS_COMPILE=aarch64-linux-gnu-
    IMAGE_PATH=arch/arm64/boot/Image
    OUTPUT_NAME=vmlinux-arm64
    ;;
  x86_64|amd64)
    CONFIG=config-x86_64
    KARCH=x86_64
    CROSS_COMPILE=x86_64-linux-gnu-
    IMAGE_PATH=arch/x86/boot/bzImage
    OUTPUT_NAME=vmlinuz-x86_64
    ;;
  *)
    echo "Unsupported target architecture: ${TARGET_ARCH}" >&2
    exit 1
    ;;
esac

mkdir -p /kbuild
tar -xf /kernel/source.tar.xz -C /kbuild --strip-components=1
cp "/kernel/${CONFIG}" /kbuild/.config

(
  cd /kbuild
  make ARCH="${KARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig && \
    make ARCH="${KARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j$((`nproc`-1)) LOCALVERSION="${LOCALVERSION}" && \
    cp "${IMAGE_PATH}" "/kernel/${OUTPUT_NAME}"
)
