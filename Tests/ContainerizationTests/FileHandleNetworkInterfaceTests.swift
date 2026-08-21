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
import ContainerizationExtras
import Foundation
import Testing
import Virtualization

@testable import Containerization

struct FileHandleNetworkInterfaceTests {

    /// `VZFileHandleNetworkDeviceAttachment` requires a connected datagram socket, so
    /// tests attach one end of a socketpair. Both ends are returned so the caller keeps
    /// the peer alive for the duration of the test.
    private struct DatagramSocketPair {
        let local: FileHandle
        let peer: FileHandle
    }

    private func makeDatagramSocketPair() throws -> DatagramSocketPair {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0)
        return DatagramSocketPair(
            local: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true),
            peer: FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        )
    }

    @Test func defaultsToDynamicAddress() throws {
        guard #available(macOS 26, *) else { return }
        let socket = try makeDatagramSocketPair()
        let iface = FileHandleNetworkInterface(fileHandle: socket.local)

        #expect(iface.fileHandle === socket.local)
        #expect(iface.ipv4Address == nil)
        #expect(iface.ipv4Gateway == nil)
        #expect(iface.macAddress == nil)
        #expect(iface.ipv6Address == nil)
        #expect(iface.ipv6Gateway == nil)
        #expect(iface.mtu == 1500)
    }

    @Test func roundTripsStaticConfiguration() throws {
        guard #available(macOS 26, *) else { return }
        let socket = try makeDatagramSocketPair()
        let cidr = try CIDRv4("192.168.64.3/24")
        let gateway = try IPv4Address("192.168.64.1")
        let mac = try MACAddress("02:42:ac:11:00:02")
        let iface: any Interface = FileHandleNetworkInterface(
            fileHandle: socket.local,
            ipv4Address: cidr,
            ipv4Gateway: gateway,
            macAddress: mac
        )

        #expect(iface.ipv4Address == cidr)
        #expect(iface.ipv4Gateway == gateway)
        #expect(iface.macAddress == mac)
    }

    @Test func deviceAttachesFileHandleAndSetsMac() throws {
        guard #available(macOS 26, *) else { return }
        let socket = try makeDatagramSocketPair()
        let mac = try MACAddress("02:42:ac:11:00:02")
        let iface = FileHandleNetworkInterface(fileHandle: socket.local, macAddress: mac)

        let device = try iface.device()
        let attachment = device.attachment as? VZFileHandleNetworkDeviceAttachment
        #expect(attachment?.fileHandle === socket.local)
        #expect(device.macAddress == VZMACAddress(string: mac.description))
    }
}
#endif
