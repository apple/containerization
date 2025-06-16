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

# Version and build configuration variables
# The default version ID 0.0.0 indicates a local development build or PRB
BUILD_CONFIGURATION ?= debug

# Commonly used locations
SWIFT := "/usr/bin/swift"
ROOT_DIR := $(shell git rev-parse --show-toplevel)
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)

# Variables for libarchive integration
LIBARCHIVE_UPSTREAM_REPO := https://github.com/libarchive/libarchive
LIBARCHIVE_UPSTREAM_VERSION := v3.7.7
LIBARCHIVE_LOCAL_DIR := workdir/libarchive

KATA_BINARY_PACKAGE := https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz

include Protobuf.Makefile
.DEFAULT_GOAL := all

.PHONY: all
all: containerization
all: init

.PHONY: release
release: BUILD_CONFIGURATION = release
release: all

.PHONY: containerization
containerization:
	@echo Building containerization binaries...
	@mkdir -p bin
	@$(SWIFT) build -c $(BUILD_CONFIGURATION)

	@echo Copying containerization binaries...
	@install $(BUILD_BIN_DIR)/cctl ./bin/
	@install $(BUILD_BIN_DIR)/containerization-integration ./bin/

	@echo Signing containerization binaries...
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/cctl
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/containerization-integration

.PHONY: init
init: vminitd
	@echo Creating init.ext4...
	@rm -f bin/init.rootfs.tar.gz bin/init.block
	@./bin/cctl rootfs create --vminitd vminitd/bin/vminitd --labels org.opencontainers.image.source=https://github.com/apple/containerization --vmexec vminitd/bin/vmexec bin/init.rootfs.tar.gz vminit:latest

.PHONY: cross-prep
cross-prep:
	@"$(MAKE)" -C vminitd cross-prep

.PHONY: vminitd
vminitd:
	@mkdir -p ./bin
	@"$(MAKE)" -C vminitd BUILD_CONFIGURATION=$(BUILD_CONFIGURATION)

.PHONY: update-libarchive-source
update-libarchive-source:
	@echo Updating the libarchive source files...
	@git clone $(LIBARCHIVE_UPSTREAM_REPO) --depth 1 --branch $(LIBARCHIVE_UPSTREAM_VERSION) $(LIBARCHIVE_LOCAL_DIR)
	@cp $(LIBARCHIVE_LOCAL_DIR)/libarchive/archive_entry.h Sources/ContainerizationArchive/CArchive/include
	@cp $(LIBARCHIVE_LOCAL_DIR)/libarchive/archive.h Sources/ContainerizationArchive/CArchive/include
	@cp $(LIBARCHIVE_LOCAL_DIR)/COPYING Sources/ContainerizationArchive/CArchive/COPYING
	@rm -rf $(LIBARCHIVE_LOCAL_DIR)

.PHONY: test
test:
	@echo Testing all test targets...
	@$(SWIFT) test --enable-code-coverage

.PHONY: integration
integration:
ifeq (,$(wildcard bin/vmlinux))
	@echo No bin/vmlinux kernel found. See fetch-default-kernel target.
	@exit 1
endif
	@echo Running the integration tests...
	@./bin/containerization-integration --bootlog ./bin/boot.log

.PHONY: fetch-default-kernel
fetch-default-kernel:
	@mkdir -p .local/ bin/
ifeq (,$(wildcard .local/kata.tar.gz))
	@curl -SsL -o .local/kata.tar.gz ${KATA_BINARY_PACKAGE}
endif
ifeq (,$(wildcard .local/vmlinux))
	@tar -zxf .local/kata.tar.gz -C .local/ --strip-components=1
	@cp -L .local/opt/kata/share/kata-containers/vmlinux.container .local/vmlinux
endif
ifeq (,$(wildcard bin/vmlinux))
	@cp .local/vmlinux bin/vmlinux
endif

.PHONY: fmt
fmt:	swift-fmt update-licenses

.PHONY: swift-fmt
SWIFT_SRC = $(shell find . -type f -name '*.swift' -not -path "*/.*" -not -path "*.pb.swift" -not -path "*.grpc.swift" -not -path "*/checkouts/*")
swift-fmt:
	@echo Applying the standard code formatting...
	@$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

.PHONY: update-licenses
update-licenses:
	@echo Updating license headers...
	@./scripts/ensure-hawkeye-exists.sh
	@.local/bin/hawkeye format --fail-if-unknown --fail-if-updated false

.PHONY: check-licenses
check-licenses:
	@echo Checking license headers existence in source files...
	@./scripts/ensure-hawkeye-exists.sh
	@.local/bin/hawkeye check --fail-if-unknown

.PHONY: serve-docs
serve-docs:
	@echo 'to browse: open http://127.0.0.1:8000/containerization/documentation/'
	@rm -rf _serve
	@mkdir -p _serve
	@cp -a _site _serve/containerization
	@python3 -m http.server --bind 127.0.0.1 --directory ./_serve

.PHONY: docs
docs: _site

_site:
	@echo Updating API documentation...
	rm -rf $@
	@scripts/make-docs.sh $@ containerization

.PHONY: cleancontent
cleancontent:
	@echo Cleaning the content...
	@rm -rf ~/Library/Application\ Support/com.apple.containerization

.PHONY: clean
clean:
	@echo Cleaning the build files...
	@rm -rf bin/
	@rm -rf _site/
	@rm -rf _serve/
	@$(SWIFT) package clean
	@"$(MAKE)" -C vminitd clean
