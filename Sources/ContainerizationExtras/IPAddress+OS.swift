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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#else
#error("Platform not supported.")
#endif

#if canImport(Darwin)
import Darwin
private let AF_LINK_TYPE = AF_LINK
#elseif canImport(Glibc) || canImport(Musl)
private let AF_LINK_TYPE = AF_PACKET
#endif

extension sockaddr_in6 {
    public init(address: IPv6Address) throws {
        self.init()
        self.sin6_family = sa_family_t(AF_INET6)
        self.sin6_port = 0
        self.sin6_flowinfo = 0
        self.sin6_scope_id = try address.scopeId()
        withUnsafeMutableBytes(of: &self.sin6_addr) { ptr in
            ptr.copyBytes(from: address.bytes)
        }
    }

    public func toIPv6Address() throws -> IPv6Address {
        let bytes: [UInt8] = withUnsafeBytes(of: sin6_addr) { ptr in
            [UInt8](ptr)  // Using bracket notation
        }
        return try IPv6Address(bytes)
    }
}

extension IPv6Address {
    public func scopeId() throws -> UInt32 {
        guard let zone else {
            return 0
        }
        if let scopeId = UInt32(zone) {
            return scopeId
        }
        let scopeId = if_nametoindex(zone)
        guard scopeId > 0 else {
            throw AddressError.invalidZoneIdentifier
        }
        return scopeId
    }
}

extension MACAddress {
    /// Get the MAC address for a network interface
    /// - Parameter zone: Interface name (e.g., "en0") or interface index (e.g., "1")
    /// - Returns: MAC address for the interface, or nil if not found
    public static func fromZone(_ zone: String) -> MACAddress? {
        // Convert zone to interface name if it's a numeric index
        let ifname: String
        if let index = UInt32(zone) {
            var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(index, &buffer) != nil else {
                return nil
            }
            // Convert CChar to UInt8 and truncate at null terminator
            let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            guard let name = String(validating: bytes, as: UTF8.self) else {
                return nil
            }
            ifname = name
        } else {
            ifname = zone
        }

        #if canImport(Darwin)
        // Darwin: Use getifaddrs() to find AF_LINK address
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0 else {
            return nil
        }
        defer { freeifaddrs(ifaddrs) }

        var currentIfaddr = ifaddrs
        while let ifaddr = currentIfaddr {
            defer { currentIfaddr = ifaddr.pointee.ifa_next }

            guard let name = ifaddr.pointee.ifa_name,
                String(cString: name) == ifname,
                let addr = ifaddr.pointee.ifa_addr
            else {
                continue
            }

            guard addr.pointee.sa_family == AF_LINK else {
                continue
            }

            let sdl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
            let macOffset = Int(sdl.sdl_nlen)
            let macLen = Int(sdl.sdl_alen)

            guard macLen == 6 else {
                continue
            }

            var macBytes = [UInt8](repeating: 0, count: 6)
            withUnsafeBytes(of: sdl.sdl_data) { ptr in
                let start = ptr.baseAddress!.advanced(by: macOffset)
                macBytes.withUnsafeMutableBytes { dst in
                    dst.copyBytes(from: UnsafeRawBufferPointer(start: start, count: 6))
                }
            }

            return try? MACAddress(macBytes)
        }

        return nil
        #elseif canImport(Glibc) || canImport(Musl)
        // Linux: Use ioctl with SIOCGIFHWADDR to get hardware address
        #if canImport(Glibc)
        let osSockDgram = Int32(SOCK_DGRAM.rawValue)
        #else
        let osSockDgram = Int32(SOCK_DGRAM)
        #endif
        let fd = socket(AF_INET, osSockDgram, 0)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }

        var ifr = ifreq()

        // Copy interface name into ifr_ifrn.ifrn_name
        guard ifname.utf8.count < MemoryLayout.size(ofValue: ifr.ifr_ifrn.ifrn_name) else {
            return nil
        }

        withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { ptr in
            _ = ifname.utf8.withContiguousStorageIfAvailable { utf8 in
                ptr.copyBytes(from: UnsafeRawBufferPointer(start: utf8.baseAddress, count: utf8.count))
            }
        }

        // Get hardware address
        guard ioctl(fd, UInt(SIOCGIFHWADDR), &ifr) >= 0 else {
            return nil
        }

        // Extract MAC address from ifr_hwaddr.sa_data
        var macBytes = [UInt8](repeating: 0, count: 6)
        withUnsafeBytes(of: ifr.ifr_ifru.ifru_hwaddr.sa_data) { ptr in
            macBytes.withUnsafeMutableBytes { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(start: ptr.baseAddress, count: 6))
            }
        }

        return try? MACAddress(macBytes)
        #endif
    }
}
