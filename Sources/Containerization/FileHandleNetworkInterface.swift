//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)

import ContainerizationError
import ContainerizationExtras
import Virtualization

/// A network interface that connects the container to an arbitrary FileHandle-backed
/// network service. The IP address might be assigned by the upstream DHCP server or
/// configured inside the container; `ipv4Address` is always nil.
@available(macOS 26, *)
public final class FileHandleNetworkInterface: Interface, Sendable {
    public let macAddress: MACAddress?
    public let ipv4Address: CIDRv4? = nil
    public let ipv4Gateway: IPv4Address? = nil
    public let fileHandle: FileHandle

    public init(fileHandle: FileHandle, macAddress: MACAddress? = nil) {
        self.macAddress = macAddress
        self.fileHandle = fileHandle
    }
}

@available(macOS 26, *)
extension FileHandleNetworkInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        config.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
        if let mac = macAddress, let vzMac = VZMACAddress(string: mac.description) {
            config.macAddress = vzMac
        }
        return config
    }
}

#endif
