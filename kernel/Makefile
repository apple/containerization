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

KSOURCE ?= https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.14.9.tar.xz
KIMAGE ?= kernel-build:0.1
CURDIR := $(shell pwd)

.DEFAULT_GOAL := all

.PHONY: all
all: kernel-build-image
all: kernel-build

.PHONY: kernel-build-image
kernel-build-image:
	container build image/ -f image/Dockerfile -t ${KIMAGE}

.PHONY: kernel-build
kernel-build:
ifeq (,$(wildcard source.tar.xz))
	curl -SsL -o source.tar.xz ${KSOURCE}
endif
	container run \
		--cpus 8 \
		--rm \
		--memory 16g \
		-v ${CURDIR}:/kernel \
		--cwd /kernel \
		${KIMAGE} \
		/bin/bash -c "./build.sh"