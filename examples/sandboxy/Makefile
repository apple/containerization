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

BUILD_CONFIGURATION ?= debug
SWIFT = /usr/bin/swift
SWIFT_STRIP := $(if $(filter release,$(BUILD_CONFIGURATION)),-Xlinker -s)
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)

.PHONY: all build clean run fmt

all: build

build:
	$(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_STRIP)
	@mkdir -p bin
	@install "$(BUILD_BIN_DIR)/sandboxy" ./bin/
	codesign --force --sign - --entitlements sandboxy.entitlements ./bin/sandboxy

clean:
	$(SWIFT) package clean
	rm -rf bin

run: build
	./bin/sandboxy

fmt:
	$(SWIFT) format --in-place --recursive Sources/
