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

# ctr-example Makefile

SWIFT = /usr/bin/swift

.PHONY: all build clean run

all: run

build:
	$(SWIFT) build --configuration release
	codesign --force --sign - --entitlements ctr-example.entitlements ./.build/release/ctr-example
	cp ./.build/release/ctr-example ./ctr-example

clean:
	$(SWIFT) package clean
	rm -f ./ctr-example

run: build
	./ctr-example

# Development targets
debug:
	$(SWIFT) build
	codesign --force --sign - --entitlements ctr-example.entitlements ./.build/debug/ctr-example

fmt:
	$(SWIFT) format --in-place --recursive Sources/
fetch-default-kernel:
	$(MAKE) -C ../.. fetch-default-kernel
	cp -L ../../.local/vmlinux ./vmlinux
