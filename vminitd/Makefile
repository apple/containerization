# Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

BUILD_CONFIGURATION := debug
SWIFT_CONFIGURATION := --swift-sdk aarch64-swift-linux-musl

# The Static Linux SDK version should match the latest released version on https://www.swift.org/install/macos/
SWIFT_SDK_URL = https://download.swift.org/swift-6.1-release/static-sdk/swift-6.1-RELEASE/swift-6.1-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz
SWIFT_SDK_CHECKSUM = 111c6f7d280a651208b8c74c0521dd99365d785c1976a6e23162f55f65379ac6
SWIFT_SDK_PATH = /tmp/$(notdir $(SWIFT_SDK_URL))

SWIFTLY_URL := https://download.swift.org/swiftly/darwin/swiftly.pkg
SWIFTLY_FILENAME = $(notdir $(SWIFTLY_URL))
VMINITD_BIN_PATH := $(shell swift build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --show-bin-path)

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
	@swift build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)
	@install $(VMINITD_BIN_PATH)/vminitd ./bin/vminitd
	@install $(VMINITD_BIN_PATH)/vmexec ./bin/vmexec

.PHONY: cross-prep
cross-prep: swiftly linux-sdk macos-sdk

.PHONY: swiftly
swiftly:
	@curl -o /var/tmp/$(SWIFTLY_FILENAME) $(SWIFTLY_URL) && \
	  installer -pkg /var/tmp/$(SWIFTLY_FILENAME) -target CurrentUserHomeDirectory && \
	  ~/.swiftly/bin/swiftly init --quiet-shell-followup && \
	  . ~/.swiftly/env.sh && \
	  hash -r
	@rm /var/tmp/$(SWIFTLY_FILENAME)
	@~/.swiftly/bin/swiftly install 6.1.0

.PHONY: linux-sdk
linux-sdk:
	@echo Installing Static Linux SDK...
	@curl -L -o $(SWIFT_SDK_PATH) $(SWIFT_SDK_URL)
	-@swift sdk install $(SWIFT_SDK_PATH) --checksum $(SWIFT_SDK_CHECKSUM)
	@rm $(SWIFT_SDK_PATH)

.PHONY: macos-sdk
macos-sdk:
	@if [ $(MACOS_MAJOR) -gt 15 ] && [ "$(MACOS_RELEASE_TYPE)" = "" ]; then \
	  "$(MAKE)" xcode-cli; \
	else \
	  "$(MAKE)" xcode; \
	fi

.PHONY: xcode-cli
xcode-cli:
	@echo Activating Xcode Command Line Tools...
	@sudo xcode-select --switch /Library/Developer/CommandLineTools

.PHONY: xcode
xcode:
	@echo Please install the latest version of Xcode 26.

.PHONY: clean
clean:
	@echo Cleaning the vminitd build files...
	@rm -f ./bin/vminitd
	@rm -f ./bin/vmexec
	@swift package clean $(SWIFT_CONFIGURATION)
