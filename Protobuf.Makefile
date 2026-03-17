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

LOCAL_DIR := $(ROOT_DIR)/.local
LOCAL_BIN_DIR := $(LOCAL_DIR)/bin

# Versions
PROTOC_VERSION := 26.1

# Protoc binary installation
PROTOC_ZIP := protoc-$(PROTOC_VERSION)-osx-universal_binary.zip
PROTOC := $(LOCAL_BIN_DIR)/protoc@$(PROTOC_VERSION)/protoc
$(PROTOC):
	@echo Downloading protocol buffers...
	@mkdir -p $(LOCAL_DIR)
	@curl -OL https://github.com/protocolbuffers/protobuf/releases/download/v$(PROTOC_VERSION)/$(PROTOC_ZIP)
	@mkdir -p $(dir $@)
	@unzip -jo $(PROTOC_ZIP) bin/protoc -d $(dir $@)
	@unzip -o $(PROTOC_ZIP) 'include/*' -d $(dir $@)
	@rm -f $(PROTOC_ZIP)

.PHONY: protoc-gen-swift
protoc-gen-swift:
	@$(SWIFT) build --product protoc-gen-swift
	@$(SWIFT) build --product protoc-gen-grpc-swift

.PHONY: protos
protos: $(PROTOC) protoc-gen-swift
	@echo Generating protocol buffers source code...
	@$(PROTOC) Sources/Containerization/SandboxContext/SandboxContext.proto \
		--plugin=protoc-gen-grpc-swift=$(BUILD_BIN_DIR)/protoc-gen-grpc-swift \
		--plugin=protoc-gen-swift=$(BUILD_BIN_DIR)/protoc-gen-swift \
		--proto_path=Sources/Containerization/SandboxContext \
		--grpc-swift_out="Sources/Containerization/SandboxContext" \
		--grpc-swift_opt=Visibility=Public \
		--swift_out="Sources/Containerization/SandboxContext" \
		--swift_opt=Visibility=Public \
		-I.
	@"$(MAKE)" update-licenses

.PHONY: clean-proto-tools
clean-proto-tools:
	@echo Cleaning proto tools...
	@rm -rf $(LOCAL_DIR)/bin/protoc*
