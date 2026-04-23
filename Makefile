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

# Build configuration variables
BUILD_CONFIGURATION ?= debug
WARNINGS_AS_ERRORS ?= true
SWIFT_CONFIGURATION := $(if $(filter-out false,$(WARNINGS_AS_ERRORS)),-Xswiftc -warnings-as-errors) --disable-automatic-resolution

# Commonly used locations
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SWIFT ?= /usr/bin/swift
else
SWIFT ?= swift
endif

ROOT_DIR := $(shell git rev-parse --show-toplevel)
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)
COV_DATA_DIR = $(shell $(SWIFT) test --show-coverage-path | xargs dirname)
COV_REPORT_FILE = $(ROOT_DIR)/code-coverage-report

# Variables for libarchive integration
LIBARCHIVE_UPSTREAM_REPO := https://github.com/libarchive/libarchive
LIBARCHIVE_UPSTREAM_VERSION := v3.7.7
LIBARCHIVE_LOCAL_DIR := workdir/libarchive

KATA_BINARY_PACKAGE := https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst

SWIFT_VERSION := $(shell cat $(ROOT_DIR)/.swift-version)
SWIFT_SDK_URL := $(shell grep '^SWIFT_SDK_URL' vminitd/Makefile | head -1 | sed 's/.*:= *//')
SWIFT_SDK_CHECKSUM := $(shell grep '^SWIFT_SDK_CHECKSUM' vminitd/Makefile | head -1 | sed 's/.*:= *//')
LINUX_DEV_IMAGE := containerization-dev:$(SWIFT_VERSION)

# Run a command inside a Linux dev container.
# Requires 'container' (https://github.com/apple/container).
# Automatically builds the dev image if it doesn't exist.
define linux_run
	@if ! command -v container > /dev/null 2>&1; then \
		echo "Error: 'container' CLI not found. Install from https://github.com/apple/container"; \
		exit 1; \
	fi
	@if ! container image list -q 2>/dev/null | grep -q "$(LINUX_DEV_IMAGE)"; then \
		echo "Building Linux dev container image..."; \
		$(MAKE) linux-image; \
	fi
	@container run --memory 8gb --cpus 4 -v $(ROOT_DIR):/workspace -w /workspace $(LINUX_DEV_IMAGE) \
		bash -c "$(1)"
endef

include Protobuf.Makefile
.DEFAULT_GOAL := all

.PHONY: deps
deps:
ifeq ($(UNAME_S),Linux)
	sudo apt-get install -y libarchive-dev libbz2-dev liblzma-dev libssl-dev
else
	@echo "No additional dependencies required on $(UNAME_S)"
endif

ifeq ($(UNAME_S),Darwin)
.PHONY: linux-image
linux-image:
	container build \
		--progress plain \
		-f images/linux-dev/Dockerfile \
		--build-arg SWIFT_VERSION=$(SWIFT_VERSION) \
		--build-arg SWIFT_SDK_URL=$(SWIFT_SDK_URL) \
		--build-arg SWIFT_SDK_CHECKSUM=$(SWIFT_SDK_CHECKSUM) \
		-t $(LINUX_DEV_IMAGE) \
		.

.PHONY: linux-build
linux-build: LIBC ?= musl
linux-build:
ifeq ($(LIBC),all)
	$(call linux_run,make containerization && make -C vminitd LIBC=glibc && make -C vminitd LIBC=musl)
else
	$(call linux_run,make containerization && make -C vminitd LIBC=$(LIBC))
endif

.PHONY: linux-test
linux-test:
	$(call linux_run,swift test $(SWIFT_CONFIGURATION))
endif

.PHONY: all
all: containerization
all: init

.PHONY: release
release: BUILD_CONFIGURATION = release
release: all

.PHONY: containerization
containerization:
	@echo Building containerization binaries...
	@$(SWIFT) --version
	@$(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)

	@echo Copying containerization binaries...
	@mkdir -p bin
	@install "$(BUILD_BIN_DIR)/cctl" ./bin/
ifeq ($(UNAME_S),Darwin)
	@install "$(BUILD_BIN_DIR)/containerization-integration" ./bin/

	@echo Signing containerization binaries...
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/cctl
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/containerization-integration
endif

.PHONY: init
init: containerization vminitd
	@echo Creating init.ext4...
	@rm -f bin/init.rootfs.tar.gz bin/init.block
	@./bin/cctl rootfs create \
		--vminitd vminitd/bin/vminitd \
		--vmexec vminitd/bin/vmexec \
		--label org.opencontainers.image.source=https://github.com/apple/containerization \
		--image vminit:latest \
		bin/init.rootfs.tar.gz

.PHONY: cross-prep
cross-prep:
	@"$(MAKE)" -C vminitd cross-prep

.PHONY: vminitd
vminitd:
	@mkdir -p ./bin
	@"$(MAKE)" -C vminitd BUILD_CONFIGURATION=$(BUILD_CONFIGURATION) WARNINGS_AS_ERRORS=$(WARNINGS_AS_ERRORS)

.PHONY: update-libarchive-source
update-libarchive-source:
	@echo Updating the libarchive source files...
	@git clone $(LIBARCHIVE_UPSTREAM_REPO) --depth 1 --branch $(LIBARCHIVE_UPSTREAM_VERSION) "$(LIBARCHIVE_LOCAL_DIR)"
	@cp "$(LIBARCHIVE_LOCAL_DIR)/libarchive/archive_entry.h" Sources/ContainerizationArchive/CArchive/include
	@cp "$(LIBARCHIVE_LOCAL_DIR)/libarchive/archive.h" Sources/ContainerizationArchive/CArchive/include
	@cp "$(LIBARCHIVE_LOCAL_DIR)/COPYING" Sources/ContainerizationArchive/CArchive/COPYING
	@rm -rf "$(LIBARCHIVE_LOCAL_DIR)"

.PHONY: test
test:
	@echo Testing all test targets...
	@$(SWIFT) test --enable-code-coverage $(SWIFT_CONFIGURATION)

.PHONY: coverage
coverage: test
	@echo Generating code coverage report...
	@xcrun llvm-cov show --compilation-dir=`pwd` \
		-instr-profile=$(COV_DATA_DIR)/default.profdata \
		--ignore-filename-regex=".build/" \
		--ignore-filename-regex=".pb.swift" \
		--ignore-filename-regex=".proto" \
		--ignore-filename-regex=".grpc.swift" \
		$(BUILD_BIN_DIR)/containerizationPackageTests.xctest/Contents/MacOS/containerizationPackageTests > $(COV_REPORT_FILE)
	@echo Code coverage report generated: $(COV_REPORT_FILE)

.PHONY: integration
integration:
ifeq (,$(wildcard bin/vmlinux))
	@echo No bin/vmlinux kernel found. See fetch-default-kernel target.
	@exit 1
endif
	@echo Running the integration tests...
	@./bin/containerization-integration

.PHONY: fetch-default-kernel
fetch-default-kernel:
	@mkdir -p .local/ bin/
ifeq (,$(wildcard .local/kata.tar.zst))
	@curl -SL -o .local/kata.tar.zst ${KATA_BINARY_PACKAGE}
endif
ifeq (,$(wildcard .local/vmlinux))
	@tar --zstd -xf .local/kata.tar.zst -C .local/ --strip-components=1
	@cp -L .local/opt/kata/share/kata-containers/vmlinux-6.18.5-177 .local/vmlinux
endif
ifeq (,$(wildcard bin/vmlinux))
	@cp .local/vmlinux bin/vmlinux
endif

.PHONY: check
check: swift-fmt-check check-licenses

.PHONY: fmt
fmt: swift-fmt update-licenses

.PHONY: swift-fmt
SWIFT_SRC = $(shell find . -type f -name '*.swift' -not -path "*/.*" -not -path "*.pb.swift" -not -path "*.grpc.swift" -not -path "*/checkouts/*")
swift-fmt:
	@echo Applying the standard code formatting...
	@$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

swift-fmt-check:
	   @echo Checking code formatting compliance...
	   @$(SWIFT) format lint --recursive --strict --configuration .swift-format-nolint $(SWIFT_SRC)

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

.PHONY: pre-commit
pre-commit:
	   cp Scripts/pre-commit.fmt .git/hooks
	   touch .git/hooks/pre-commit
	   cat .git/hooks/pre-commit | grep -v 'hooks/pre-commit\.fmt' > /tmp/pre-commit.new || true
	   echo 'PRECOMMIT_NOFMT=$${PRECOMMIT_NOFMT} $$(git rev-parse --show-toplevel)/.git/hooks/pre-commit.fmt' >> /tmp/pre-commit.new
	   mv /tmp/pre-commit.new .git/hooks/pre-commit
	   chmod +x .git/hooks/pre-commit

.PHONY: serve-docs
serve-docs:
	@echo 'to browse: open http://127.0.0.1:8000/containerization/documentation/'
	@rm -rf _serve
	@mkdir -p _serve
	@cp -a _site _serve/containerization
	@python3 -m http.server --bind 127.0.0.1 --directory ./_serve

.PHONY: docs
docs:
	@echo Updating API documentation...
	@rm -rf _site
	@scripts/make-docs.sh _site containerization

.PHONY: cleancontent
cleancontent:
	@echo Cleaning the content...
	@rm -rf ~/Library/Application\ Support/com.apple.containerization

.PHONY: clean
clean:
	@echo Cleaning build files...
	@rm -rf bin/
	@rm -rf _site/
	@rm -rf _serve/
	@rm -f $(COV_REPORT_FILE)
	@$(SWIFT) package clean
	@"$(MAKE)" -C vminitd clean
