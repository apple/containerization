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

/// PAX extended header support for TAR archives.
///
/// PAX headers allow storing extended metadata that doesn't fit in the
/// traditional TAR header format:
/// - Arbitrary length file paths
/// - File sizes > 8GB
/// - Sub-second timestamps
/// - Large UID/GID values
/// - UTF-8 file names
///
/// Format: Each record is `LENGTH KEY=VALUE\n` where LENGTH includes itself.
package enum TarPax {
    /// Standard PAX keywords.
    package enum Keyword {
        package static let path = "path"
        package static let linkpath = "linkpath"
        package static let size = "size"
        package static let uid = "uid"
        package static let gid = "gid"
        package static let uname = "uname"
        package static let gname = "gname"
        package static let mtime = "mtime"
        package static let atime = "atime"
        package static let ctime = "ctime"
    }

    /// Create a PAX record with the format: "LENGTH KEY=VALUE\n"
    /// The length includes the length field itself, which requires iteration to compute.
    package static func makeRecord(key: String, value: String) -> [UInt8] {
        // Content is: " key=value\n" (note leading space after length)
        let content = " \(key)=\(value)\n"
        let contentBytes = Array(content.utf8)

        // Calculate the total length including the length field itself.
        // This requires iteration because the length field's size affects the total.
        var lengthDigits = 1
        var totalLength = contentBytes.count + lengthDigits

        while String(totalLength).count > lengthDigits {
            lengthDigits = String(totalLength).count
            totalLength = contentBytes.count + lengthDigits
        }

        // Build the final record
        let lengthString = String(totalLength)
        return Array(lengthString.utf8) + contentBytes
    }

    /// Parse PAX extended header data into key-value pairs.
    package static func parseRecords(_ data: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        var offset = 0

        while offset < data.count {
            // Parse length
            var lengthEnd = offset
            while lengthEnd < data.count && data[lengthEnd] != 0x20 {  // space
                lengthEnd += 1
            }

            guard lengthEnd < data.count else { break }

            let lengthBytes = data[offset..<lengthEnd]
            let lengthString = String(decoding: lengthBytes, as: UTF8.self)
            guard let recordLength = Int(lengthString) else { break }

            // Extract the record (excluding the length and space)
            let recordStart = lengthEnd + 1
            let recordEnd = min(offset + recordLength, data.count)

            guard recordEnd > recordStart else { break }

            // Record format is "key=value\n"
            let recordBytes = data[recordStart..<recordEnd]
            let record = String(decoding: recordBytes, as: UTF8.self)

            // Find the '=' separator
            if let equalsIndex = record.firstIndex(of: "=") {
                let key = String(record[record.startIndex..<equalsIndex])
                var value = String(record[record.index(after: equalsIndex)...])

                // Remove trailing newline if present
                if value.hasSuffix("\n") {
                    value.removeLast()
                }

                result[key] = value
            }

            offset += recordLength
        }

        return result
    }

    /// Determine if a header requires PAX extended headers.
    package static func requiresPax(_ header: TarHeader) -> Bool {
        let pathBytes = Array(header.path.utf8)

        // Check if path fits in traditional format
        if pathBytes.count > TarConstants.maxNameLength {
            // Path doesn't fit in name field alone, check if we can split
            if pathBytes.count > TarConstants.maxNameLength + TarConstants.maxPrefixLength {
                // Too long even with prefix
                return true
            }
            // Check if there's a valid split point
            if TarHeader.findPathSplit(pathBytes) == nil {
                // No valid split point, need PAX
                return true
            }
        }

        // Link name too long
        if header.linkName.utf8.count > TarHeaderField.linkNameSize {
            return true
        }

        // File size too large
        if header.size > TarConstants.maxTraditionalSize {
            return true
        }

        // UID/GID too large (max 7 octal digits = 2097151)
        if header.uid > 2_097_151 || header.gid > 2_097_151 {
            return true
        }

        return false
    }

    /// Build PAX extended header data for a given header.
    package static func buildExtendedData(for header: TarHeader) -> [UInt8] {
        var records: [UInt8] = []

        // Path (always include if PAX is needed, regardless of why)
        if header.path.utf8.count > TarConstants.maxNameLength {
            records.append(contentsOf: makeRecord(key: Keyword.path, value: header.path))
        }

        // Link path
        if header.linkName.utf8.count > TarHeaderField.linkNameSize {
            records.append(contentsOf: makeRecord(key: Keyword.linkpath, value: header.linkName))
        }

        // Size
        if header.size > TarConstants.maxTraditionalSize {
            records.append(contentsOf: makeRecord(key: Keyword.size, value: String(header.size)))
        }

        // UID
        if header.uid > 2_097_151 {
            records.append(contentsOf: makeRecord(key: Keyword.uid, value: String(header.uid)))
        }

        // GID
        if header.gid > 2_097_151 {
            records.append(contentsOf: makeRecord(key: Keyword.gid, value: String(header.gid)))
        }

        return records
    }

    /// Create a PAX extended header entry.
    /// Returns the complete header block(s) including the PAX data.
    package static func createPaxEntry(for header: TarHeader) -> [UInt8] {
        let paxData = buildExtendedData(for: header)

        guard !paxData.isEmpty else {
            return []
        }

        let paxHeader = TarHeader(
            path: TarConstants.paxHeaderName,
            mode: 0o644,
            uid: 0,
            gid: 0,
            size: Int64(paxData.count),
            mtime: header.mtime,
            entryType: .paxExtended,
            userName: header.userName,
            groupName: header.groupName
        )

        let headerBlock: [UInt8]
        if let serialized = paxHeader.serialize() {
            headerBlock = serialized
        } else {
            // Fallback: create minimal header manually
            headerBlock = createMinimalPaxHeader(size: paxData.count, mtime: header.mtime)
        }

        let paddedData = padToBlockBoundary(paxData)

        return headerBlock + paddedData
    }

    /// Create a minimal PAX header block when normal serialization fails.
    private static func createMinimalPaxHeader(size: Int, mtime: Int64) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: TarConstants.blockSize)

        // Name: ././@PaxHeader
        let name = Array(TarConstants.paxHeaderName.utf8)
        for (i, byte) in name.prefix(TarHeaderField.nameSize).enumerated() {
            header[TarHeaderField.nameOffset + i] = byte
        }

        // Mode: 0644
        let modeOctal = TarHeader.formatOctal(0o644, width: TarHeaderField.modeSize)
        for (i, byte) in modeOctal.enumerated() {
            header[TarHeaderField.modeOffset + i] = byte
        }

        // UID: 0
        let uidOctal = TarHeader.formatOctal(0, width: TarHeaderField.uidSize)
        for (i, byte) in uidOctal.enumerated() {
            header[TarHeaderField.uidOffset + i] = byte
        }

        // GID: 0
        let gidOctal = TarHeader.formatOctal(0, width: TarHeaderField.gidSize)
        for (i, byte) in gidOctal.enumerated() {
            header[TarHeaderField.gidOffset + i] = byte
        }

        // Size
        let sizeOctal = TarHeader.formatOctal(Int64(size), width: TarHeaderField.sizeSize)
        for (i, byte) in sizeOctal.enumerated() {
            header[TarHeaderField.sizeOffset + i] = byte
        }

        // Mtime
        let mtimeOctal = TarHeader.formatOctal(mtime, width: TarHeaderField.mtimeSize)
        for (i, byte) in mtimeOctal.enumerated() {
            header[TarHeaderField.mtimeOffset + i] = byte
        }

        // Checksum placeholder (spaces)
        for i in 0..<TarHeaderField.checksumSize {
            header[TarHeaderField.checksumOffset + i] = 0x20
        }

        // Type flag: 'x' for PAX extended
        header[TarHeaderField.typeFlagOffset] = TarEntryType.paxExtended.rawValue

        // Magic
        for (i, byte) in TarConstants.magic.enumerated() {
            header[TarHeaderField.magicOffset + i] = byte
        }

        // Version
        for (i, byte) in TarConstants.version.enumerated() {
            header[TarHeaderField.versionOffset + i] = byte
        }

        var checksum = 0
        for byte in header {
            checksum += Int(byte)
        }

        let checksumOctal = TarHeader.formatOctal(Int64(checksum), width: TarHeaderField.checksumSize - 1)
        for (i, byte) in checksumOctal.enumerated() {
            header[TarHeaderField.checksumOffset + i] = byte
        }
        header[TarHeaderField.checksumOffset + 6] = 0x00
        header[TarHeaderField.checksumOffset + 7] = 0x20

        return header
    }

    /// Pad data to 512-byte block boundary.
    private static func padToBlockBoundary(_ data: [UInt8]) -> [UInt8] {
        let remainder = data.count % TarConstants.blockSize
        if remainder == 0 {
            return data
        }

        let paddingNeeded = TarConstants.blockSize - remainder
        return data + [UInt8](repeating: 0, count: paddingNeeded)
    }

    /// Apply PAX overrides to a parsed header.
    package static func applyOverrides(_ paxData: [String: String], to header: inout TarHeader) {
        if let path = paxData[Keyword.path] {
            header.path = path
        }

        if let linkpath = paxData[Keyword.linkpath] {
            header.linkName = linkpath
        }

        if let sizeString = paxData[Keyword.size], let size = Int64(sizeString) {
            header.size = size
        }

        if let uidString = paxData[Keyword.uid], let uid = UInt32(uidString) {
            header.uid = uid
        }

        if let gidString = paxData[Keyword.gid], let gid = UInt32(gidString) {
            header.gid = gid
        }

        if let uname = paxData[Keyword.uname] {
            header.userName = uname
        }

        if let gname = paxData[Keyword.gname] {
            header.groupName = gname
        }
    }
}
