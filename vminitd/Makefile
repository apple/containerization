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
SWIFT_WARNING_CONFIG := $(if $(filter-out false,$(WARNINGS_AS_ERRORS)),-Xswiftc -warnings-as-errors)
SWIFT_CONFIGURATION := --swift-sdk aarch64-swift-linux-musl $(SWIFT_WARNING_CONFIG) -Xlinker -s

SWIFT_VERSION := 6.2.3
SWIFT_SDK_URL := https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz
SWIFT_SDK_PATH := /tmp/$(notdir $(SWIFT_SDK_URL))

SWIFTLY_URL := https://download.swift.org/swiftly/darwin/swiftly.pkg
SWIFTLY_FILENAME := $(notdir $(SWIFTLY_URL))
SWIFTLY_BIN_DIR ?= ~/.swiftly/bin
BUILD_BIN_DIR := $(shell swift build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --show-bin-path)

MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)
MACOS_RELEASE_TYPE := $(shell sw_vers | grep ReleaseType)

.DEFAULT_GOAL := all

.PHONY: all
all: 
	@echo Building vminitd and vmexec...
	@mkdir -p ./bin/
	@rm -f ./bin/vminitd
	@rm -f ./bin/vmexec
	@swift --version
	@swift build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)
	@install "$(BUILD_BIN_DIR)/vminitd" ./bin/
	@install "$(BUILD_BIN_DIR)/vmexec" ./bin/

.PHONY: cross-prep
cross-prep: linux-sdk macos-sdk

.PHONY: swiftly
swiftly:
	@if ! command -v ${SWIFTLY_BIN_DIR}/swiftly > /dev/null 2>&1; then \
		echo "Installing Swiftly..."; \
		curl -o /var/tmp/$(SWIFTLY_FILENAME) $(SWIFTLY_URL) && \
		installer -pkg /var/tmp/$(SWIFTLY_FILENAME) -target CurrentUserHomeDirectory && \
		${SWIFTLY_BIN_DIR}/swiftly init --quiet-shell-followup --skip-install && \
		. ~/.swiftly/env.sh && \
		hash -r && \
		rm /var/tmp/$(SWIFTLY_FILENAME); \
	fi
	
.PHONY: swift
swift: swiftly
	@echo Installing Swift $(SWIFT_VERSION)...
	@${SWIFTLY_BIN_DIR}/swiftly install $(SWIFT_VERSION)

.PHONY: linux-sdk
linux-sdk: swift
	@echo Installing Static Linux SDK...
	@curl -L -o $(SWIFT_SDK_PATH) $(SWIFT_SDK_URL)
	-@swift sdk install $(SWIFT_SDK_PATH)
	@rm $(SWIFT_SDK_PATH)

.PHONY: macos-sdk
macos-sdk:
	# Consider switching back to `xcode-cltools`, when possible.
	@if [ $(MACOS_MAJOR) -gt 15 ] && [ "$(MACOS_RELEASE_TYPE)" = "" ]; then \
	  "$(MAKE)" xcode; \
	else \
	  "$(MAKE)" xcode; \
	fi

.PHONY: xcode-cltools
xcode-cltools:
	@echo Activating Xcode Command Line Tools...
	@sudo xcode-select --switch /Library/Developer/CommandLineTools

.PHONY: xcode
xcode:
	@echo "Please install the latest version of Xcode 26 and set the path for the active developer directory using \`sudo xcode-select -s <PATH_TO_XCODE>\`".

.PHONY: clean
clean:
	@echo Cleaning the vminitd build files...
	@rm -f ./bin/vminitd
	@rm -f ./bin/vmexec
	@swift package clean $(SWIFT_CONFIGURATION)
