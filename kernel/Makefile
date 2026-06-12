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

KSOURCE ?= https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.5.tar.xz
KIMAGE ?= kernel-build:0.1
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
GIT_VERSION := $(shell git -C $(MAKEFILE_DIR) rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
TARGET_ARCH ?=

# Resolve the effective target arch (TARGET_ARCH override, else host).
EFFECTIVE_ARCH := $(if $(TARGET_ARCH),$(TARGET_ARCH),$(shell uname -m))
ifneq (,$(filter $(EFFECTIVE_ARCH),aarch64))
EFFECTIVE_ARCH := arm64
endif
ifneq (,$(filter $(EFFECTIVE_ARCH),amd64))
EFFECTIVE_ARCH := x86_64
endif

# Compressed (vmlinuz) for x86_64 bzImage; uncompressed (vmlinux) for arm64 Image.
ifeq ($(EFFECTIVE_ARCH),x86_64)
KERNEL_OUTPUT := vmlinuz-x86_64
else
KERNEL_OUTPUT := vmlinux-arm64
endif

BIN_DIR := $(abspath $(MAKEFILE_DIR)/../bin)

.DEFAULT_GOAL := all

.PHONY: all
all: kernel-build-image
all: kernel-build
all: kernel-install

.PHONY: kernel-build-image
kernel-build-image:
	container build $(MAKEFILE_DIR)/image -f $(MAKEFILE_DIR)/image/Dockerfile -t ${KIMAGE}

.PHONY: kernel-build
kernel-build:
ifeq (,$(wildcard $(MAKEFILE_DIR)/source.tar.xz))
	curl -SsL -o $(MAKEFILE_DIR)/source.tar.xz ${KSOURCE}
endif
	container run \
		--cpus 8 \
		--rm \
		--memory 16g \
		-v $(MAKEFILE_DIR):/kernel \
		--env LOCALVERSION=-cz-${GIT_VERSION} \
		$(if $(TARGET_ARCH),--env TARGET_ARCH=$(TARGET_ARCH),) \
		--cwd /kernel \
		${KIMAGE} \
		/bin/bash -c "./build.sh"

.PHONY: kernel-install
kernel-install:
	@mkdir -p $(BIN_DIR)
	@cp -L $(MAKEFILE_DIR)/$(KERNEL_OUTPUT) $(BIN_DIR)/$(KERNEL_OUTPUT)
	@echo "Installed $(KERNEL_OUTPUT) -> $(BIN_DIR)/$(KERNEL_OUTPUT)"

.PHONY: x86_64
x86_64:
	$(MAKE) all TARGET_ARCH=x86_64
