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

/// TAR archive constants and header structure.
///
/// TAR header format (POSIX ustar):
/// ```
/// Offset  Size  Field
/// 0       100   File name
/// 100     8     File mode (octal)
/// 108     8     Owner UID (octal)
/// 116     8     Owner GID (octal)
/// 124     12    File size (octal)
/// 136     12    Modification time (octal)
/// 148     8     Checksum
/// 156     1     Type flag
/// 157     100   Link name
/// 257     6     Magic ("ustar\0")
/// 263     2     Version ("00")
/// 265     32    Owner user name
/// 297     32    Owner group name
/// 329     8     Device major number
/// 337     8     Device minor number
/// 345     155   Filename prefix
/// 500     12    Padding (zeros)
/// ```
enum TarConstants {
    /// Size of a TAR block in bytes.
    static let blockSize = 512

    /// USTAR magic string.
    static let magic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72, 0x00]  // "ustar\0"

    /// USTAR version.
    static let version: [UInt8] = [0x30, 0x30]  // "00"

    /// Maximum file size representable in traditional TAR (11 octal digits).
    /// 8,589,934,591 bytes (~8GB)
    static let maxTraditionalSize: Int64 = 0o77777777777

    /// Maximum path length in traditional TAR name field.
    static let maxNameLength = 100

    /// Maximum path length using prefix field.
    static let maxPrefixLength = 155

    /// PAX header name used when writing extended headers.
    static let paxHeaderName = "././@PaxHeader"

    /// Maximum size for PAX extended header data (1MB).
    static let maxPaxSize = 1024 * 1024
}

/// TAR entry type flags.
public enum TarEntryType: UInt8, Sendable {
    /// Regular file (or '\0' for old TAR).
    case regular = 0x30  // '0'

    /// Hard link.
    case hardLink = 0x31  // '1'

    /// Symbolic link.
    case symbolicLink = 0x32  // '2'

    /// Character device.
    case characterDevice = 0x33  // '3'

    /// Block device.
    case blockDevice = 0x34  // '4'

    /// Directory.
    case directory = 0x35  // '5'

    /// FIFO (named pipe).
    case fifo = 0x36  // '6'

    /// Contiguous file.
    case contiguous = 0x37  // '7'

    /// PAX extended header (per-file).
    case paxExtended = 0x78  // 'x'

    /// PAX global extended header.
    case paxGlobal = 0x67  // 'g'

    /// Null byte (old TAR regular file).
    case regularAlt = 0x00

    /// Whether this entry type represents a regular file.
    public var isRegularFile: Bool {
        self == .regular || self == .regularAlt
    }
}

/// Header field offsets and sizes.
enum TarHeaderField {
    static let nameOffset = 0
    static let nameSize = 100

    static let modeOffset = 100
    static let modeSize = 8

    static let uidOffset = 108
    static let uidSize = 8

    static let gidOffset = 116
    static let gidSize = 8

    static let sizeOffset = 124
    static let sizeSize = 12

    static let mtimeOffset = 136
    static let mtimeSize = 12

    static let checksumOffset = 148
    static let checksumSize = 8

    static let typeFlagOffset = 156
    static let typeFlagSize = 1

    static let linkNameOffset = 157
    static let linkNameSize = 100

    static let magicOffset = 257
    static let magicSize = 6

    static let versionOffset = 263
    static let versionSize = 2

    static let unameOffset = 265
    static let unameSize = 32

    static let gnameOffset = 297
    static let gnameSize = 32

    static let devMajorOffset = 329
    static let devMajorSize = 8

    static let devMinorOffset = 337
    static let devMinorSize = 8

    static let prefixOffset = 345
    static let prefixSize = 155
}

/// Represents a parsed TAR header.
public struct TarHeader: Sendable {
    /// File path (may come from PAX extended header).
    public var path: String

    /// File mode/permissions.
    public var mode: UInt32

    /// Owner user ID.
    public var uid: UInt32

    /// Owner group ID.
    public var gid: UInt32

    /// Content size in bytes. For regular files this is the file data size.
    /// For PAX headers this is the size of the metadata records.
    public var size: Int64

    /// Modification time (Unix timestamp).
    public var mtime: Int64

    /// Entry type.
    public var entryType: TarEntryType

    /// Link target (for symbolic/hard links).
    public var linkName: String

    /// Owner user name.
    public var userName: String

    /// Owner group name.
    public var groupName: String

    /// Device major number.
    public var deviceMajor: UInt32

    /// Device minor number.
    public var deviceMinor: UInt32

    public init(
        path: String,
        mode: UInt32 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        size: Int64 = 0,
        mtime: Int64 = 0,
        entryType: TarEntryType = .regular,
        linkName: String = "",
        userName: String = "root",
        groupName: String = "root",
        deviceMajor: UInt32 = 0,
        deviceMinor: UInt32 = 0
    ) {
        self.path = path
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.mtime = mtime
        self.entryType = entryType
        self.linkName = linkName
        self.userName = userName
        self.groupName = groupName
        self.deviceMajor = deviceMajor
        self.deviceMinor = deviceMinor
    }
}

// MARK: - Octal String Conversion

extension TarHeader {
    /// Convert an integer to an octal string with the specified width.
    /// The string is null-terminated and right-padded with spaces if needed.
    static func formatOctal(_ value: Int64, width: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width)

        // Format as octal string (width - 1 digits to leave room for null terminator)
        let octalString = String(value, radix: 8)
        let paddedString = String(repeating: "0", count: max(0, width - 1 - octalString.count)) + octalString

        // Copy to result buffer
        let bytes = Array(paddedString.utf8)
        let copyCount = min(bytes.count, width - 1)
        for i in 0..<copyCount {
            result[i] = bytes[i]
        }

        return result
    }

    /// Parse an octal string from a TAR header field.
    static func parseOctal(_ bytes: ArraySlice<UInt8>) -> Int64 {
        // Check for GNU binary extension (high bit set)
        if let first = bytes.first, first & 0x80 != 0 {
            // Binary format: remaining bytes are big-endian integer
            var value: Int64 = 0
            for (index, byte) in bytes.enumerated() {
                let b = index == 0 ? byte & 0x7F : byte  // Clear high bit on first byte
                value = (value << 8) | Int64(b)
            }
            return value
        }

        // Standard octal ASCII format
        var value: Int64 = 0
        for byte in bytes {
            // Skip leading spaces and stop at null/space terminator
            if byte == 0x20 {  // space
                if value == 0 { continue }  // leading space
                break  // trailing space
            }
            if byte == 0x00 { break }  // null terminator

            // Convert ASCII digit to value
            if byte >= 0x30 && byte <= 0x37 {  // '0' to '7'
                value = value * 8 + Int64(byte - 0x30)
            }
        }
        return value
    }

    /// Parse a null-terminated string from a TAR header field.
    static func parseString(_ bytes: ArraySlice<UInt8>) -> String {
        // Find null terminator or end of slice
        var endIndex = bytes.startIndex
        for i in bytes.indices {
            if bytes[i] == 0 {
                break
            }
            endIndex = i + 1
        }

        let stringBytes = bytes[bytes.startIndex..<endIndex]
        return String(decoding: stringBytes, as: UTF8.self)
    }
}

// MARK: - Header Serialization

extension TarHeader {
    /// Serialize this header to a 512-byte TAR header block.
    /// Returns nil if the path is too long and PAX headers are needed.
    func serialize() -> [UInt8]? {
        var header = [UInt8](repeating: 0, count: TarConstants.blockSize)

        // Determine if we can fit the path in traditional format
        let pathBytes = Array(path.utf8)
        if pathBytes.count > TarConstants.maxNameLength + TarConstants.maxPrefixLength {
            // Path too long even with prefix - need PAX
            return nil
        }

        // Try to split path into prefix and name
        var nameBytes: [UInt8]
        var prefixBytes: [UInt8] = []

        if pathBytes.count <= TarConstants.maxNameLength {
            nameBytes = pathBytes
        } else {
            // Find a slash to split on
            guard let splitIndex = Self.findPathSplit(pathBytes) else {
                // Can't split - need PAX
                return nil
            }
            prefixBytes = Array(pathBytes[0..<splitIndex])
            nameBytes = Array(pathBytes[(splitIndex + 1)...])
        }

        if size > TarConstants.maxTraditionalSize {
            return nil
        }

        // Name field
        for (i, byte) in nameBytes.prefix(TarConstants.maxNameLength).enumerated() {
            header[TarHeaderField.nameOffset + i] = byte
        }

        // Mode
        let modeOctal = Self.formatOctal(Int64(mode), width: TarHeaderField.modeSize)
        for (i, byte) in modeOctal.enumerated() {
            header[TarHeaderField.modeOffset + i] = byte
        }

        // UID
        let uidOctal = Self.formatOctal(Int64(uid), width: TarHeaderField.uidSize)
        for (i, byte) in uidOctal.enumerated() {
            header[TarHeaderField.uidOffset + i] = byte
        }

        // GID
        let gidOctal = Self.formatOctal(Int64(gid), width: TarHeaderField.gidSize)
        for (i, byte) in gidOctal.enumerated() {
            header[TarHeaderField.gidOffset + i] = byte
        }

        // Size
        let sizeOctal = Self.formatOctal(size, width: TarHeaderField.sizeSize)
        for (i, byte) in sizeOctal.enumerated() {
            header[TarHeaderField.sizeOffset + i] = byte
        }

        // Modification time
        let mtimeOctal = Self.formatOctal(mtime, width: TarHeaderField.mtimeSize)
        for (i, byte) in mtimeOctal.enumerated() {
            header[TarHeaderField.mtimeOffset + i] = byte
        }

        // Checksum placeholder (spaces for calculation)
        for i in 0..<TarHeaderField.checksumSize {
            header[TarHeaderField.checksumOffset + i] = 0x20  // space
        }

        // Type flag
        header[TarHeaderField.typeFlagOffset] = entryType.rawValue

        // Link name
        let linkBytes = Array(linkName.utf8)
        for (i, byte) in linkBytes.prefix(TarHeaderField.linkNameSize).enumerated() {
            header[TarHeaderField.linkNameOffset + i] = byte
        }

        // Magic
        for (i, byte) in TarConstants.magic.enumerated() {
            header[TarHeaderField.magicOffset + i] = byte
        }

        // Version
        for (i, byte) in TarConstants.version.enumerated() {
            header[TarHeaderField.versionOffset + i] = byte
        }

        // User name
        let unameBytes = Array(userName.utf8)
        for (i, byte) in unameBytes.prefix(TarHeaderField.unameSize).enumerated() {
            header[TarHeaderField.unameOffset + i] = byte
        }

        // Group name
        let gnameBytes = Array(groupName.utf8)
        for (i, byte) in gnameBytes.prefix(TarHeaderField.gnameSize).enumerated() {
            header[TarHeaderField.gnameOffset + i] = byte
        }

        // Device numbers
        let devMajorOctal = Self.formatOctal(Int64(deviceMajor), width: TarHeaderField.devMajorSize)
        for (i, byte) in devMajorOctal.enumerated() {
            header[TarHeaderField.devMajorOffset + i] = byte
        }

        let devMinorOctal = Self.formatOctal(Int64(deviceMinor), width: TarHeaderField.devMinorSize)
        for (i, byte) in devMinorOctal.enumerated() {
            header[TarHeaderField.devMinorOffset + i] = byte
        }

        // Prefix
        for (i, byte) in prefixBytes.prefix(TarHeaderField.prefixSize).enumerated() {
            header[TarHeaderField.prefixOffset + i] = byte
        }

        // Calculate and write checksum
        let checksum = calculateChecksum(header)
        let checksumOctal = Self.formatOctal(Int64(checksum), width: TarHeaderField.checksumSize - 1)
        for (i, byte) in checksumOctal.enumerated() {
            header[TarHeaderField.checksumOffset + i] = byte
        }
        // Checksum field ends with null and space
        header[TarHeaderField.checksumOffset + 6] = 0x00
        header[TarHeaderField.checksumOffset + 7] = 0x20

        return header
    }

    /// Find a valid split point for USTAR prefix/name format.
    /// Returns the index of the '/' to split on, or nil if no valid split exists.
    static func findPathSplit(_ pathBytes: [UInt8]) -> Int? {
        // Need to find a '/' such that:
        // - prefix (before '/') is <= 155 bytes
        // - name (after '/') is <= 100 bytes
        let slash = UInt8(ascii: "/")

        for i in stride(from: min(pathBytes.count - 1, TarConstants.maxPrefixLength), through: 0, by: -1) {
            if pathBytes[i] == slash {
                let remainingLength = pathBytes.count - i - 1
                if remainingLength <= TarConstants.maxNameLength {
                    return i
                }
            }
        }
        return nil
    }

    /// Calculate the TAR header checksum.
    private func calculateChecksum(_ header: [UInt8]) -> Int {
        var sum = 0
        for byte in header {
            sum += Int(byte)
        }
        return sum
    }
}

// MARK: - Header Parsing

extension TarHeader {
    /// Parse a TAR header from a 512-byte block.
    static func parse(from block: [UInt8]) -> TarHeader? {
        guard block.count >= TarConstants.blockSize else {
            return nil
        }

        // Check if this is an empty block (end of archive)
        if block.allSatisfy({ $0 == 0 }) {
            return nil
        }

        // Verify checksum
        guard verifyChecksum(block) else {
            return nil
        }

        // Parse name (may need to combine with prefix)
        let nameSlice = block[TarHeaderField.nameOffset..<(TarHeaderField.nameOffset + TarHeaderField.nameSize)]
        let prefixSlice = block[TarHeaderField.prefixOffset..<(TarHeaderField.prefixOffset + TarHeaderField.prefixSize)]

        let name = parseString(nameSlice)
        let prefix = parseString(prefixSlice)

        let path: String
        if prefix.isEmpty {
            path = name
        } else {
            path = prefix + "/" + name
        }

        // Parse other fields
        let modeSlice = block[TarHeaderField.modeOffset..<(TarHeaderField.modeOffset + TarHeaderField.modeSize)]
        let uidSlice = block[TarHeaderField.uidOffset..<(TarHeaderField.uidOffset + TarHeaderField.uidSize)]
        let gidSlice = block[TarHeaderField.gidOffset..<(TarHeaderField.gidOffset + TarHeaderField.gidSize)]
        let sizeSlice = block[TarHeaderField.sizeOffset..<(TarHeaderField.sizeOffset + TarHeaderField.sizeSize)]
        let mtimeSlice = block[TarHeaderField.mtimeOffset..<(TarHeaderField.mtimeOffset + TarHeaderField.mtimeSize)]
        let linkNameSlice = block[TarHeaderField.linkNameOffset..<(TarHeaderField.linkNameOffset + TarHeaderField.linkNameSize)]
        let unameSlice = block[TarHeaderField.unameOffset..<(TarHeaderField.unameOffset + TarHeaderField.unameSize)]
        let gnameSlice = block[TarHeaderField.gnameOffset..<(TarHeaderField.gnameOffset + TarHeaderField.gnameSize)]
        let devMajorSlice = block[TarHeaderField.devMajorOffset..<(TarHeaderField.devMajorOffset + TarHeaderField.devMajorSize)]
        let devMinorSlice = block[TarHeaderField.devMinorOffset..<(TarHeaderField.devMinorOffset + TarHeaderField.devMinorSize)]

        let typeFlag = block[TarHeaderField.typeFlagOffset]
        let entryType = TarEntryType(rawValue: typeFlag) ?? .regular

        return TarHeader(
            path: path,
            mode: UInt32(parseOctal(modeSlice)),
            uid: UInt32(parseOctal(uidSlice)),
            gid: UInt32(parseOctal(gidSlice)),
            size: parseOctal(sizeSlice),
            mtime: parseOctal(mtimeSlice),
            entryType: entryType,
            linkName: parseString(linkNameSlice),
            userName: parseString(unameSlice),
            groupName: parseString(gnameSlice),
            deviceMajor: UInt32(parseOctal(devMajorSlice)),
            deviceMinor: UInt32(parseOctal(devMinorSlice))
        )
    }

    /// Verify the checksum of a TAR header block.
    private static func verifyChecksum(_ block: [UInt8]) -> Bool {
        // Get the stored checksum
        let checksumSlice = block[TarHeaderField.checksumOffset..<(TarHeaderField.checksumOffset + TarHeaderField.checksumSize)]
        let storedChecksum = parseOctal(checksumSlice)

        // Calculate checksum (treating checksum field as spaces)
        var calculatedChecksum = 0
        for (i, byte) in block.enumerated() {
            if i >= TarHeaderField.checksumOffset && i < TarHeaderField.checksumOffset + TarHeaderField.checksumSize {
                calculatedChecksum += 0x20  // space
            } else {
                calculatedChecksum += Int(byte)
            }
        }

        return storedChecksum == Int64(calculatedChecksum)
    }
}
