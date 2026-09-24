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
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)

# `-` signs ad hoc. The USB entitlement needs SIGN_IDENTITY, PROVISIONING_PROFILE and TEAM_ID.
SIGN_IDENTITY ?= -
PROVISIONING_PROFILE ?=
# Adds the application-identifier and team-identifier entitlements the profile requires.
TEAM_ID ?=
BUNDLE_ID ?= com.example.containerization.usb-passthrough
ENTITLEMENTS ?= usb-passthrough.entitlements

# Needs a USB-enabled kernel from `make -C ../../kernel`; the kata kernel won't work.
KERNEL ?= ../../bin/vmlinux-arm64
INITFS ?= ../../bin/initfs.ext4

APP = bin/USBPassthrough.app

.PHONY: all build run entitlements clean fmt

all: build

build:
	$(SWIFT) build -c $(BUILD_CONFIGURATION)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	@install "$(BUILD_BIN_DIR)/usb-passthrough" $(APP)/Contents/MacOS/
	@sed 's/BUNDLE_ID/$(BUNDLE_ID)/' Info.plist > $(APP)/Contents/Info.plist
	$(if $(PROVISIONING_PROFILE),@cp "$(PROVISIONING_PROFILE)" $(APP)/Contents/embedded.provisionprofile)
	@cp $(ENTITLEMENTS) bin/entitlements.plist
	$(if $(TEAM_ID),@/usr/libexec/PlistBuddy \
		-c "Add :com.apple.application-identifier string $(TEAM_ID).$(BUNDLE_ID)" \
		-c "Add :com.apple.developer.team-identifier string $(TEAM_ID)" \
		bin/entitlements.plist)
	codesign --force --sign "$(SIGN_IDENTITY)" --entitlements bin/entitlements.plist $(APP)

# Run the executable directly to keep output in this terminal.
run: build
	$(APP)/Contents/MacOS/usb-passthrough --kernel "$(KERNEL)" --initfs "$(INITFS)"

# Show the signature and embedded entitlements.
entitlements:
	codesign -dvv $(APP)
	codesign -d --entitlements - $(APP)

clean:
	$(SWIFT) package clean
	rm -rf bin

fmt:
	$(SWIFT) format --in-place --recursive Sources/
