public struct IPAddressError: Error, Equatable, Hashable, CustomStringConvertible {
    public var description: String {
        String(describing: self.base)
    }

    @usableFromInline
    enum Base: Equatable, Hashable, Sendable {
        case unableToParse
        case invalidZoneIdentifier
        case invalidIPv4Suffix
        case multipleEllipsis
        case invalidHexGroup
        case malformedAddress
        case incompleteAddress
    }

    @usableFromInline
    let base: Base

    @inlinable
    init(_ base: Base) { self.base = base }

    public static var unableToParse: Self {
        Self(.unableToParse)
    }

    public static var invalidZoneIdentifier: Self {
        Self(.invalidZoneIdentifier)
    }

    public static var invalidIPv4SuffixInIPv6Address: Self {
        Self(.invalidIPv4Suffix)
    }

    public static var multipleEllipsis: Self {
        Self(.multipleEllipsis)
    }

    public static var invalidHexGroup: Self {
        Self(.invalidHexGroup)
    }

    public static var malformedAddress: Self {
        Self(.malformedAddress)
    }

    public static var incompleteAddress: Self {
        Self(.incompleteAddress)
    }
}
