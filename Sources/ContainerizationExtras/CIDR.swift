/// Describes an IPv4 or IPv6 CIDR address block.
@frozen
public enum CIDR: CustomStringConvertible, Equatable, Sendable, Hashable {

    case v4(IPv4Address, Prefix)
    case v6(IPv6Address, Prefix)

    /// Create a CIDR address block.
    ///
    /// Normalizes the address to the network address.
    /// For example, `"192.168.1.100/24"` becomes `192.168.1.0/24`.
    ///
    /// To preserve the original IP address, use `CIDR.parse(_:)`.
    public init(_ cidr: String) throws {
        let (ip, prefix) = try Self.parse(cidr)
        try self.init(ip, prefix: prefix)
    }

    /// Parse CIDR notation into `IPAddress` and `Prefix`.
    ///
    /// Example:
    /// ```swift
    /// let (ip, prefix) = try CIDR.parse("192.168.1.100/24")
    /// let cidr = try CIDR(ip, prefix: prefix)
    /// cidr.address: 192.168.1.0  // normalized
    /// ```
    public static func parse(_ cidr: String) throws -> (ip: IPAddress, prefix: Prefix) {
        let split = cidr.split(separator: "/")
        guard split.count == 2 else {
            throw Error.invalidCIDR(cidr: cidr)
        }
        guard let block = UInt8(split[1]) else {
            throw Error.invalidCIDR(cidr: cidr)
        }

        let ip = try IPAddress(String(split[0]))

        // Validate prefix length for IP version
        let prefix: Prefix
        switch ip {
        case .v4:
            guard block <= 32, let validPrefix = Prefix(length: block) else {
                throw Error.invalidCIDR(cidr: cidr)
            }
            prefix = validPrefix
        case .v6:
            guard block <= 128, let validPrefix = Prefix(length: block) else {
                throw Error.invalidCIDR(cidr: cidr)
            }
            prefix = validPrefix
        }

        return (ip, prefix)
    }

    /// Create a CIDR address from a member IP and a prefix length.
    ///
    /// Normalizes the address to the network address.
    ///
    /// Example:
    /// ```swift
    /// let ip = try IPAddress("192.168.1.100")
    /// let prefix = Prefix(length: 24)
    /// let cidr = try CIDR(ip, prefix: prefix)
    /// cidr.address: 192.168.1.0
    /// ```
    public init(_ address: IPAddress, prefix: Prefix) throws {
        switch address {
        case .v4(let addr):
            guard prefix.length <= 32 else {
                throw Self.Error.invalidCIDR(cidr: "\(address)/\(prefix)")
            }
            let networkAddr = IPv4Address(addr.value & prefix.prefixMask32)
            self = .v4(networkAddr, prefix)
        case .v6(let addr):
            guard prefix.length <= 128 else {
                throw Self.Error.invalidCIDR(cidr: "\(address)/\(prefix)")
            }
            let networkAddr = IPv6Address(addr.value & prefix.prefixMask128, zone: addr.zone)
            self = .v6(networkAddr, prefix)
        }
    }

    /// Create the smallest IPv4 CIDR block that includes the lower and upper bounds.
    ///
    /// - Parameters:
    ///   - lower: The lower bound IPv4 address
    ///   - upper: The upper bound IPv4 address
    /// - Returns: The smallest CIDR block containing both addresses
    /// - Throws: If lower > upper
    public static func v4Range(lower: IPv4Address, upper: IPv4Address) throws -> CIDR {
        guard lower.value <= upper.value else {
            throw Error.invalidAddressRange(lower: lower.description, upper: upper.description)
        }

        for length in 1...32 {
            let prefixLength = Prefix(unchecked: UInt8(length))
            let mask = prefixLength.prefixMask32
            if (lower.value & mask) != (upper.value & mask) {
                let prefix = Prefix(unchecked: UInt8(length - 1))
                let networkAddr = IPv4Address(lower.value & prefix.prefixMask32)
                let cidr = CIDR.v4(networkAddr, prefix)
                // Validate coverage
                guard cidr.contains(.v4(lower)) && cidr.contains(.v4(upper)) else {
                    throw Error.invalidAddressRange(lower: lower.description, upper: upper.description)
                }
                return cidr
            }
        }
        // Same address - /32 block
        let prefix = Prefix(unchecked: 32)
        let networkAddr = IPv4Address(lower.value & prefix.prefixMask32)
        return .v4(networkAddr, prefix)
    }

    /// Create the smallest IPv6 CIDR block that includes the lower and upper bounds.
    ///
    /// - Parameters:
    ///   - lower: The lower bound IPv6 address
    ///   - upper: The upper bound IPv6 address
    /// - Returns: The smallest CIDR block containing both addresses
    /// - Throws: If lower > upper or zones don't match
    public static func v6Range(lower: IPv6Address, upper: IPv6Address) throws -> CIDR {
        guard lower.value <= upper.value && lower.zone == upper.zone else {
            throw Error.invalidAddressRange(lower: lower.description, upper: upper.description)
        }

        for length in 1...128 {
            let prefixLength = Prefix(unchecked: UInt8(length))
            let mask = prefixLength.prefixMask128
            if (lower.value & mask) != (upper.value & mask) {
                let prefix = Prefix(unchecked: UInt8(length - 1))
                let networkAddr = IPv6Address(lower.value & prefix.prefixMask128, zone: lower.zone)
                let cidr = CIDR.v6(networkAddr, prefix)
                // Validate coverage
                guard cidr.contains(.v6(lower)) && cidr.contains(.v6(upper)) else {
                    throw Error.invalidAddressRange(lower: lower.description, upper: upper.description)
                }
                return cidr
            }
        }
        // Same address - /128 block
        let prefix = Prefix(unchecked: 128)
        let networkAddr = IPv6Address(lower.value & prefix.prefixMask128, zone: lower.zone)
        return .v6(networkAddr, prefix)
    }

    /// Create the smallest CIDR block that includes the lower and upper bounds.
    ///
    /// For type-safe construction, prefer `v4Range(lower:upper:)` or `v6Range(lower:upper:)`.
    public init(lower: IPAddress, upper: IPAddress) throws {
        switch (lower, upper) {
        case (.v4(let lowerAddr), .v4(let upperAddr)):
            self = try Self.v4Range(lower: lowerAddr, upper: upperAddr)
        case (.v6(let lowerAddr), .v6(let upperAddr)):
            self = try Self.v6Range(lower: lowerAddr, upper: upperAddr)
        default:
            throw Self.Error.invalidAddressRange(lower: lower.description, upper: upper.description)
        }
    }

    /// The normalized network address of this CIDR block.
    @inlinable
    public var address: IPAddress {
        switch self {
        case .v4(let addr, _):
            return .v4(addr)
        case .v6(let addr, _):
            return .v6(addr)
        }
    }

    /// The prefix of this CIDR block.
    @inlinable
    public var prefix: Prefix {
        switch self {
        case .v4(_, let prefix), .v6(_, let prefix):
            return prefix
        }
    }

    /// The lowest address in this CIDR block
    @inlinable
    public var lower: IPAddress {
        self.address
    }

    /// The highest address in this CIDR block (broadcast address).
    @inlinable
    public var upper: IPAddress {
        switch self {
        case .v4(let addr, let prefix):
            return .v4(IPv4Address(addr.value | prefix.suffixMask32))
        case .v6(let addr, let prefix):
            return .v6(IPv6Address(addr.value | prefix.suffixMask128, zone: addr.zone))
        }
    }

    /// Return true if the CIDR block contains the specified address.
    ///
    /// Compares network portion of the given IP address.
    @inlinable
    public func contains(_ ip: IPAddress) -> Bool {
        switch (self, ip) {
        case (.v4(let network, let prefix), .v4(let ip)):
            return network.value == (ip.value & prefix.prefixMask32)
        case (.v6(let network, let prefix), .v6(let ip)):
            guard network.zone == ip.zone else {
                return false
            }
            return network.value == (ip.value & prefix.prefixMask128)
        default:
            return false
        }
    }

    /// Retrieve the text representation of the CIDR block.
    public var description: String {
        "\(address)/\(prefix)"
    }
}

extension CIDR {
    public enum Error: Swift.Error {
        case invalidCIDR(cidr: String)
        case invalidAddressRange(lower: String, upper: String)
    }
}
