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

KSOURCE ?= https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.14.9.tar.xz
KIMAGE ?= ghcr.io/apple/test-images/kernel-build:latest

all:
ifeq (,$(wildcard source.tar.xz))
	curl -SsL -o source.tar.xz ${KSOURCE}
endif
	../bin/cctl run \
		--cpus 8 \
		--memory 16384 \
		--fs-size 32768 \
		--kernel ../bin/vmlinux \
		--init ../bin/init.block \
		--image ${KIMAGE} \
		--mount .:/kernel \
		--cwd /kernel \
		-- /bin/bash -c "./build.sh"
