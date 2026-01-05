//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
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

import CArchive

/// Represents the configuration settings for an `ArchiveWriter`.
///
/// This struct allows specifying the archive format, compression filter,
/// various format-specific options, and preferred locales for string encoding.
public struct ArchiveWriterConfiguration {
    /// The desired archive format
    public var format: Format
    /// The compression filter to apply to the archive
    public var filter: Filter
    /// An array of format-specific options to apply to the archive.
    /// This includes options like compression level and extended attribute format.
    public var options: [Options]
    /// An array of preferred locale identifiers for string encoding
    public var locales: [String]

    /// Initializes a new `ArchiveWriterConfiguration`.
    ///
    /// Sets up the configuration with the specified format, filter, options, and locales.
    public init(
        format: Format, filter: Filter, options: [Options] = [], locales: [String] = ["en_US.UTF-8", "C.UTF-8"]
    ) {
        self.format = format
        self.filter = filter
        self.options = options
        self.locales = locales
    }
}

extension ArchiveWriter {
    internal func setFormat(_ format: Format) throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }
        let r = archive_write_set_format(underlying, format.code)
        guard r == ARCHIVE_OK else { throw ArchiveError.unableToSetFormat(r, format) }
    }

    internal func addFilter(_ filter: Filter) throws {
        guard let underlying = self.underlying else { throw ArchiveError.noUnderlyingArchive }
        let r = archive_write_add_filter(underlying, filter.code)
        guard r == ARCHIVE_OK else { throw ArchiveError.unableToAddFilter(r, filter) }
    }

    internal func setOptions(_ options: [Options]) throws {
        try options.forEach {
            switch $0 {
            case .compressionLevel(let level):
                try wrap(
                    archive_write_set_option(underlying, nil, "compression-level", "\(level)"),
                    ArchiveError.unableToSetOption, underlying: self.underlying)
            case .compression(.store):
                try wrap(
                    archive_write_set_option(underlying, nil, "compression", "store"), ArchiveError.unableToSetOption,
                    underlying: self.underlying)
            case .compression(.deflate):
                try wrap(
                    archive_write_set_option(underlying, nil, "compression", "deflate"), ArchiveError.unableToSetOption,
                    underlying: self.underlying)
            case .xattrformat(let value):
                let v = value.description
                try wrap(
                    archive_write_set_option(underlying, nil, "xattrheader", v), ArchiveError.unableToSetOption,
                    underlying: self.underlying)
            }
        }
    }
}

public enum Options {
    case compressionLevel(UInt32)
    case compression(Compression)
    case xattrformat(XattrFormat)

    public enum Compression {
        case store
        case deflate
    }

    public enum XattrFormat: String, CustomStringConvertible {
        case schily
        case libarchive
        case all

        public var description: String {
            switch self {
            case .libarchive:
                return "LIBARCHIVE"
            case .schily:
                return "SCHILY"
            case .all:
                return "ALL"
            }
        }
    }
}

/// An enumeration of the supported archive formats.
public enum Format: String, Sendable {
    /// POSIX-standard `ustar` archives
    case ustar
    case gnutar
    /// POSIX `pax interchange format` archives
    case pax
    case paxRestricted
    /// POSIX octet-oriented cpio archives
    case cpio
    case cpioNewc
    /// Zip archive
    case zip
    /// two different variants of shar archives
    case shar
    case sharDump
    /// ISO9660 CD images
    case iso9660
    /// 7-Zip archives
    case sevenZip
    /// ar archives
    case arBSD
    case arGNU
    /// mtree file tree descriptions
    case mtree
    /// XAR archives
    case xar

    internal var code: CInt {
        switch self {
        case .ustar: return ARCHIVE_FORMAT_TAR_USTAR
        case .pax: return ARCHIVE_FORMAT_TAR_PAX_INTERCHANGE
        case .paxRestricted: return ARCHIVE_FORMAT_TAR_PAX_RESTRICTED
        case .gnutar: return ARCHIVE_FORMAT_TAR_GNUTAR
        case .cpio: return ARCHIVE_FORMAT_CPIO_POSIX
        case .cpioNewc: return ARCHIVE_FORMAT_CPIO_AFIO_LARGE
        case .zip: return ARCHIVE_FORMAT_ZIP
        case .shar: return ARCHIVE_FORMAT_SHAR_BASE
        case .sharDump: return ARCHIVE_FORMAT_SHAR_DUMP
        case .iso9660: return ARCHIVE_FORMAT_ISO9660
        case .sevenZip: return ARCHIVE_FORMAT_7ZIP
        case .arBSD: return ARCHIVE_FORMAT_AR_BSD
        case .arGNU: return ARCHIVE_FORMAT_AR_GNU
        case .mtree: return ARCHIVE_FORMAT_MTREE
        case .xar: return ARCHIVE_FORMAT_XAR
        }
    }
}

/// An enumeration of the supported filters (compression / encoding standards) for an archive.
public enum Filter: String, Sendable {
    case none
    case gzip
    case bzip2
    case compress
    case lzma
    case xz
    case uu
    case rpm
    case lzip
    case lrzip
    case lzop
    case grzip
    case lz4

    internal var code: CInt {
        switch self {
        case .none: return ARCHIVE_FILTER_NONE
        case .gzip: return ARCHIVE_FILTER_GZIP
        case .bzip2: return ARCHIVE_FILTER_BZIP2
        case .compress: return ARCHIVE_FILTER_COMPRESS
        case .lzma: return ARCHIVE_FILTER_LZMA
        case .xz: return ARCHIVE_FILTER_XZ
        case .uu: return ARCHIVE_FILTER_UU
        case .rpm: return ARCHIVE_FILTER_RPM
        case .lzip: return ARCHIVE_FILTER_LZIP
        case .lrzip: return ARCHIVE_FILTER_LRZIP
        case .lzop: return ARCHIVE_FILTER_LZOP
        case .grzip: return ARCHIVE_FILTER_GRZIP
        case .lz4: return ARCHIVE_FILTER_LZ4
        }
    }
}
