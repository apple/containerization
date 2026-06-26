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
UNAME_M := $(shell uname -m)
KERNEL_ARCH := $(if $(filter $(UNAME_M),aarch64 arm64),arm64,$(UNAME_M))
# Candidate kernel filenames in bin/ (compiled vmlinuz first, kata-fetched vmlinux fallback).
ifeq ($(KERNEL_ARCH),x86_64)
KERNEL_CANDIDATES := bin/vmlinuz-x86_64 bin/vmlinux-x86_64
else
KERNEL_CANDIDATES := bin/vmlinux-$(KERNEL_ARCH)
endif
# In-repo KVM-capable kernel built by `make -C kernel` (vmlinuz for x86_64 bzImage,
# vmlinux for arm64 Image). linux-integration requires this; the kata-fetched
# kernel under bin/ does not enable KVM.
ifeq ($(KERNEL_ARCH),x86_64)
LINUX_INTEGRATION_KERNEL := kernel/vmlinuz-x86_64
else
LINUX_INTEGRATION_KERNEL := kernel/vmlinux-$(KERNEL_ARCH)
endif
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

KATA_BINARY_PACKAGE := https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz
CLOUD_HYPERVISOR_URL := https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v52.0/cloud-hypervisor-static-aarch64
# SHA256 of the v52.0 aarch64 static binary (verified locally from the
# upstream release artifact). Bump alongside CLOUD_HYPERVISOR_URL.
CLOUD_HYPERVISOR_SHA256 := bf004ddc1a148f47caa87ac49a783b8dbd6bf9bc27abe522ed197df7b982d3b1

SWIFT_VERSION := $(shell cat $(ROOT_DIR)/.swift-version)
SWIFT_SDK_URL := $(shell grep '^SWIFT_SDK_URL' vminitd/Makefile | head -1 | sed 's/.*:= *//')
SWIFT_SDK_CHECKSUM := $(shell grep '^SWIFT_SDK_CHECKSUM' vminitd/Makefile | head -1 | sed 's/.*:= *//')
LINUX_DEV_IMAGE := containerization-dev:$(SWIFT_VERSION)

# Literal `,` for use inside $(call ...) arguments — bare commas are
# treated as the call's argument separator and split the value early.
comma := ,

# Run a command inside a Linux dev container.
# Requires 'container' (https://github.com/apple/container).
# Automatically builds the dev image if it doesn't exist.
#
# Bind-mounts $(ROOT_DIR)/.local/integration-cache → the dev container's
# appRoot (`~/.local/share/com.apple.containerization`) so cctl-populated
# imageStore content (e.g. `vminit:latest` from `make init`, plus images
# pulled by the integration suite like alpine) persists across `container
# run` invocations. Without this, every `make linux-integration` re-pulls
# alpine and re-imports vminit, which dominates per-suite ramp-up. The
# macOS path gets this for free because $HOME persists.
#
# $(1): bash command to run inside the container.
# $(2): optional extra flags for `container run` (empty by default). Use this
#       for linux-integration to pass `--kernel kernel/vmlinux-<arch>` so
#       /dev/kvm is exposed in the dev container's Linux VM (the kata kernel
#       fetched by `make fetch-default-kernel` does not enable KVM).
define linux_run
	@if ! command -v container > /dev/null 2>&1; then \
		echo "Error: 'container' CLI not found. Install from https://github.com/apple/container"; \
		exit 1; \
	fi
	@if ! container image list -q 2>/dev/null | grep -q "$(LINUX_DEV_IMAGE)"; then \
		echo "Building Linux dev container image..."; \
		$(MAKE) linux-image; \
	fi
	@mkdir -p $(ROOT_DIR)/.local/integration-cache
	@container run --rm $(2) --memory 16gb --cpus 8 --virtualization \
		-v $(ROOT_DIR):/workspace \
		-v $(ROOT_DIR)/.local/integration-cache:/root/.local/share/com.apple.containerization \
		-w /workspace $(LINUX_DEV_IMAGE) \
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
	$(call linux_run,make containerization && make -C vminitd LIBC=glibc && make -C vminitd LIBC=musl && make init)
else
	$(call linux_run,make containerization && make -C vminitd LIBC=$(LIBC) && make init)
endif

.PHONY: linux-test
linux-test:
	$(call linux_run,swift test $(SWIFT_CONFIGURATION))

.PHONY: build-cloud-hypervisor
# Build cloud-hypervisor from the patched source at .local/cloud-hypervisor and
# install it to bin/cloud-hypervisor. Runs inside the Linux dev container so the
# resulting binary is aarch64-linux-gnu and can run nested-virt under
# `container run --virtualization`. Installs build deps + rustup the first
# time. Forces HOME=/root since the container inherits the host HOME otherwise,
# which breaks rustup's $HOME/.cargo path.
#
# Prerequisite: clone cloud-hypervisor into .local/cloud-hypervisor (any
# revision compatible with the v52.0 REST surface this repo targets). There
# is no fetch target — pin the revision deliberately. Example:
#   git clone -b v52.0 https://github.com/cloud-hypervisor/cloud-hypervisor \
#       .local/cloud-hypervisor
build-cloud-hypervisor:
ifeq (,$(wildcard .local/cloud-hypervisor/Cargo.toml))
	@echo "missing .local/cloud-hypervisor source checkout." >&2
	@echo "clone the cloud-hypervisor repo into .local/cloud-hypervisor before running this target, e.g.:" >&2
	@echo "  git clone -b v52.0 https://github.com/cloud-hypervisor/cloud-hypervisor .local/cloud-hypervisor" >&2
	@exit 1
endif
	$(call linux_run,export HOME=/root && if ! command -v curl >/dev/null 2>&1; then apt-get update && apt-get install -y --no-install-recommends curl ca-certificates build-essential pkg-config libssl-dev; fi && if [ ! -x /root/.cargo/bin/cargo ]; then curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal; fi && . /root/.cargo/env && cd .local/cloud-hypervisor && cargo build --release --bin cloud-hypervisor && cp target/release/cloud-hypervisor /workspace/bin/cloud-hypervisor && chmod +x /workspace/bin/cloud-hypervisor)

.PHONY: build-virtiofsd
# Build virtiofsd from the source at .local/virtiofsd and install it to
# bin/virtiofsd. Runs inside the Linux dev container so the resulting
# binary is aarch64-linux-gnu and matches the cloud-hypervisor binary
# built by `make build-cloud-hypervisor`.
#
# Prerequisite: clone virtiofsd into .local/virtiofsd (any revision the
# scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch applies
# cleanly to). There is no fetch target — pin the revision deliberately:
#   git clone https://gitlab.com/virtio-fs/virtiofsd .local/virtiofsd
#
# virtiofsd has two hard build deps that aren't in the base dev image:
#   * libcap-ng-dev — capng crate is unconditional in [dependencies].
#   * libseccomp-dev — Cargo.toml has `default = ["seccomp"]` and
#     `[[bin]] required-features = ["seccomp"]`, and libseccomp-sys is a
#     -sys crate that links against the system library via pkg-config.
# Both are required even though we run with `--sandbox none` (capng is
# called for capability-drop at startup, before any sandbox setup).
#
# Before building, applies the patch at
# scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch (see
# that file for rationale). Idempotent: skips if already applied via
# git apply --reverse --check.
#
# Sentinel for the apt-get block is libcap-ng + libseccomp via pkg-config
# (not `command -v curl`) so this target works correctly even after
# `build-cloud-hypervisor` has already installed curl in the same dev
# container.
build-virtiofsd:
ifeq (,$(wildcard .local/virtiofsd/Cargo.toml))
	@echo "missing .local/virtiofsd source checkout." >&2
	@echo "clone the virtiofsd repo into .local/virtiofsd before running this target, e.g.:" >&2
	@echo "  git clone https://gitlab.com/virtio-fs/virtiofsd .local/virtiofsd" >&2
	@exit 1
endif
	$(call linux_run,export HOME=/root && \
		if ! pkg-config --exists libcap-ng libseccomp 2>/dev/null; then \
			apt-get update && apt-get install -y --no-install-recommends \
				curl ca-certificates build-essential pkg-config libssl-dev \
				libcap-ng-dev libseccomp-dev; \
		fi && \
		if [ ! -x /root/.cargo/bin/cargo ]; then \
			curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal; \
		fi && \
		. /root/.cargo/env && \
		cd /workspace/.local/virtiofsd && \
		if git apply --check /workspace/scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch 2>/dev/null; then \
			git apply /workspace/scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch && \
			echo "applied virtiofsd cap-drop patch"; \
		elif git apply --reverse --check /workspace/scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch 2>/dev/null; then \
			echo "virtiofsd cap-drop patch already applied"; \
		else \
			echo "ERROR: virtiofsd cap-drop patch does not apply cleanly" >&2; \
			exit 1; \
		fi && \
		cargo build --release && \
		cp target/release/virtiofsd /workspace/bin/virtiofsd && \
		chmod +x /workspace/bin/virtiofsd)

.PHONY: linux-integration
linux-integration:
ifeq (,$(wildcard bin/cloud-hypervisor))
	@echo "missing bin/cloud-hypervisor; run 'make fetch-cloud-hypervisor' first"
	@exit 1
endif
ifeq (,$(wildcard bin/virtiofsd))
	@echo "missing bin/virtiofsd; run 'make build-virtiofsd' first"
	@exit 1
endif
ifeq (,$(wildcard $(LINUX_INTEGRATION_KERNEL)))
	@echo "missing $(LINUX_INTEGRATION_KERNEL); run 'make -C kernel' first to build a KVM-capable kernel"
	@exit 1
endif
ifeq (,$(wildcard bin/containerization-integration))
	@echo "missing bin/containerization-integration; run 'make linux-build' first"
	@exit 1
endif
ifeq (,$(wildcard bin/initfs.ext4))
	@echo "missing bin/initfs.ext4; run 'make init' first (this also seeds the persistent imageStore at .local/integration-cache)"
	@exit 1
endif
	$(call linux_run,CONTAINERIZATION_RELAXED_SANDBOX=1 ./bin/containerization-integration --kernel ./$(LINUX_INTEGRATION_KERNEL) --ch-binary ./bin/cloud-hypervisor --virtiofsd-binary ./bin/virtiofsd --max-concurrency 1,--kernel $(LINUX_INTEGRATION_KERNEL))

# Builds the x86_64 deployment tarball.
#
# Cross-compiles cctl, vminitd, cloud-hypervisor, and virtiofsd to
# x86_64-linux-musl inside the aarch64 Linux dev container (using the
# musl cross toolchain + static C deps installed by the dev image),
# packs an initfs.ext4 with the x86_64 vminitd inside, and emits
# bin/containerization-x86_64-<sha>.tar.gz.
#
# Depends on linux-image so that Dockerfile / build-musl-x86_64-deps.sh
# changes are picked up automatically. `container build` is cheap when
# layers are cached, so the no-change path is a few seconds of overhead.
#
# Prereqs:
#   * .local/cloud-hypervisor and .local/virtiofsd source checkouts
#     (see build-cloud-hypervisor / build-virtiofsd for clone URLs).
#   * kernel/vmlinuz-x86_64 (preferred) or kernel/vmlinux-x86_64 present.
#     Build via `make -C kernel TARGET_ARCH=x86_64` (or `make -C kernel x86_64`).
#     The script fails hard if neither is present.
.PHONY: dist-x86_64
dist-x86_64: linux-image
	$(call linux_run,./scripts/build-dist-x86_64.sh)
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
	@install "$(BUILD_BIN_DIR)/containerization-integration" ./bin/
ifeq ($(UNAME_S),Darwin)
	@echo Signing containerization binaries...
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/cctl
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/containerization-integration
endif

.PHONY: init
init: containerization vminitd
	@echo Creating init.ext4...
	@rm -f bin/init.rootfs.tar.gz bin/init.block bin/initfs.ext4
	@./bin/cctl rootfs create \
		--vminitd vminitd/bin/vminitd \
		--vmexec vminitd/bin/vmexec \
		--ext4 ./bin/initfs.ext4 \
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
	@kernel="$$(for f in $(KERNEL_CANDIDATES); do [ -f $$f ] && echo $$f && break; done)"; \
	if [ -z "$$kernel" ]; then \
		echo "No kernel found. Looked for: $(KERNEL_CANDIDATES). See fetch-default-kernel target or build via kernel/Makefile."; \
		exit 1; \
	fi; \
	echo "Running the integration tests with kernel $$kernel..."; \
	./bin/containerization-integration --kernel "$$kernel"

.PHONY: fetch-default-kernel
fetch-default-kernel:
	@mkdir -p .local/ bin/
ifeq (,$(wildcard .local/kata.tar.gz))
	@curl -SsL -o .local/kata.tar.gz ${KATA_BINARY_PACKAGE}
endif
ifeq (,$(wildcard .local/vmlinux-$(KERNEL_ARCH)))
	@tar -zxf .local/kata.tar.gz -C .local/ --strip-components=1
	@cp -L .local/opt/kata/share/kata-containers/vmlinux.container .local/vmlinux-$(KERNEL_ARCH)
endif
ifeq (,$(wildcard bin/vmlinux-$(KERNEL_ARCH)))
	@cp .local/vmlinux-$(KERNEL_ARCH) bin/vmlinux-$(KERNEL_ARCH)
endif

.PHONY: fetch-cloud-hypervisor
fetch-cloud-hypervisor:
	@mkdir -p bin
	@curl -SsL -o bin/cloud-hypervisor $(CLOUD_HYPERVISOR_URL)
	@actual=$$(shasum -a 256 bin/cloud-hypervisor | awk '{print $$1}'); \
	if [ "$$actual" != "$(CLOUD_HYPERVISOR_SHA256)" ]; then \
		echo "ERROR: cloud-hypervisor checksum mismatch" >&2; \
		echo "  expected: $(CLOUD_HYPERVISOR_SHA256)" >&2; \
		echo "  actual:   $$actual" >&2; \
		rm -f bin/cloud-hypervisor; \
		exit 1; \
	fi
	@chmod +x bin/cloud-hypervisor

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

.PHONY: examples
examples:
	@echo Building examples...
	@mkdir -p bin
	@"$(MAKE)" -C examples/sandboxy build BUILD_CONFIGURATION=$(BUILD_CONFIGURATION)
	@install examples/sandboxy/bin/sandboxy ./bin/
	@codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/sandboxy

.PHONY: clean
clean:
	@echo Cleaning build files...
	@rm -rf bin/
	@rm -rf _site/
	@rm -rf _serve/
	@rm -f $(COV_REPORT_FILE)
	@$(SWIFT) package clean
	@"$(MAKE)" -C vminitd clean
