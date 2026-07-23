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

BUILD_CONFIGURATION ?= debug
WARNINGS_AS_ERRORS ?= true
export GIT_COMMIT := $(shell git rev-parse HEAD)
export GIT_TAG := $(shell git describe --tags --exact-match 2>/dev/null || echo "")
export BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
SWIFT_WARNING_CONFIG := $(if $(filter-out false,$(WARNINGS_AS_ERRORS)),-Xswiftc -warnings-as-errors)
# MUSL_ARCH selects which Static Linux SDK triple to build against
# ($(MUSL_ARCH)-swift-linux-musl). Defaults to the host architecture
# so the in-tree aarch64 flow works unchanged, but callers can override
# (e.g. `make MUSL_ARCH=x86_64` for the dist-x86_64 cross-build path).
ifndef MUSL_ARCH
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),arm64)
MUSL_ARCH := aarch64
else ifeq ($(UNAME_M),aarch64)
MUSL_ARCH := aarch64
else
MUSL_ARCH := x86_64
endif
endif

LIBC ?= musl
ifeq ($(LIBC),musl)
SWIFT_SDK_FLAGS := --swift-sdk $(MUSL_ARCH)-swift-linux-musl
endif

SWIFT_CONFIGURATION := $(SWIFT_SDK_FLAGS) $(SWIFT_WARNING_CONFIG) -Xlinker -s --disable-automatic-resolution

SWIFT_VERSION := 6.3.0
SWIFT_SDK_URL := https://download.swift.org/swift-6.3-release/static-sdk/swift-6.3-RELEASE/swift-6.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SWIFT_SDK_CHECKSUM := d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c
SWIFT_SDK_PATH := /tmp/$(notdir $(SWIFT_SDK_URL))

# vminitd is built inside the Linux dev container (see the root Makefile's
# `vminitd` target, which routes through `linux_run` on macOS), so `swift`
# is always the toolchain on PATH inside that container. The host no longer
# needs Swiftly or a locally-installed Static Linux SDK.
SYSTEM_TYPE := $(shell uname -s)
SWIFT ?= swift
# Lazily evaluated (`=`, not `:=`) so `swift build --swift-sdk ... --show-bin-path`
# only runs for the `all` target — which runs inside the Linux dev container
# where the Static Linux SDK exists. Evaluating it at parse time would fail on a
# macOS host (which no longer installs the SDK) for targets like `clean`.
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --show-bin-path)

ifeq ($(SYSTEM_TYPE),Darwin)
MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)
MACOS_RELEASE_TYPE := $(shell sw_vers | grep ReleaseType)
endif

.DEFAULT_GOAL := all

# INSTALL_DIR is where built binaries land. Defaults to ./bin so the
# in-tree aarch64 flow is unchanged. The dist-x86_64 cross-build
# overrides this to keep its artifacts out of vminitd/bin/.
INSTALL_DIR ?= ./bin

.PHONY: all
all:
	@echo Building vminitd and vmexec...
	@mkdir -p $(INSTALL_DIR)
	@rm -f $(INSTALL_DIR)/vminitd
	@rm -f $(INSTALL_DIR)/vmexec
	@$(SWIFT) --version
	@$(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)
	@install "$(BUILD_BIN_DIR)/vminitd" $(INSTALL_DIR)/
	@install "$(BUILD_BIN_DIR)/vmexec" $(INSTALL_DIR)/

.PHONY: linux-sdk
# Installs the Static Linux SDK into the active Swift toolchain. Used inside
# plain Swift Linux containers that don't already bake in the SDK (e.g. the
# `linux-build.yml` compile-check and the CI `buildGuest` job). The dev image
# built by `make linux-image` installs the same SDK at image-build time, so it
# does not need this target.
linux-sdk:
	@echo Installing Static Linux SDK...
	@curl -L -o $(SWIFT_SDK_PATH) $(SWIFT_SDK_URL)
	-@$(SWIFT) sdk install $(SWIFT_SDK_PATH) --checksum $(SWIFT_SDK_CHECKSUM)
	@rm $(SWIFT_SDK_PATH)

.PHONY: clean
clean:
	@echo Cleaning the vminitd build files...
	@rm -f ./bin/vminitd
	@rm -f ./bin/vmexec
	@rm -rf .build
