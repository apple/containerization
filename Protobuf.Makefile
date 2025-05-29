LOCAL_DIR := $(ROOT_DIR)/.local
LOCALBIN := $(LOCAL_DIR)/bin

## Versions
PROTOC_VERSION=26.1

# protoc binary installation
PROTOC_ZIP = protoc-$(PROTOC_VERSION)-osx-universal_binary.zip
PROTOC = $(LOCALBIN)/protoc@$(PROTOC_VERSION)/protoc
$(PROTOC):
	@echo Downloading protocol buffers...
	@mkdir -p $(LOCAL_DIR)
	@curl -OL https://github.com/protocolbuffers/protobuf/releases/download/v$(PROTOC_VERSION)/$(PROTOC_ZIP)
	@mkdir -p $(dir $@)
	@unzip -jo $(PROTOC_ZIP) bin/protoc -d $(dir $@)
	@unzip -o $(PROTOC_ZIP) 'include/*' -d $(dir $@)
	@rm -f $(PROTOC_ZIP)

protoc_gen_grpc_swift:
	swift build --product protoc-gen-grpc-swift

protoc-gen-swift:
	swift build --product protoc-gen-swift

.PHONY: protos
protos: $(PROTOC) protoc_gen_grpc_swift protoc-gen-swift
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
