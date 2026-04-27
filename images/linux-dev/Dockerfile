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

ARG SWIFT_VERSION=6.3
FROM swift:${SWIFT_VERSION}-noble

RUN apt-get update \
 && apt-get install -y make libarchive-dev libbz2-dev liblzma-dev libssl-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

ARG SWIFT_SDK_URL
ARG SWIFT_SDK_CHECKSUM
RUN if [ -n "$SWIFT_SDK_URL" ]; then \
      swift sdk install "$SWIFT_SDK_URL" --checksum "$SWIFT_SDK_CHECKSUM"; \
    fi
