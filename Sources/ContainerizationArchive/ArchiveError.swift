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
import Foundation

/// An enumeration of the errors that can be thrown while interacting with an archive.
public enum ArchiveError: Error, CustomStringConvertible {
    case unableToCreateArchive
    case noUnderlyingArchive
    case noArchiveInCallback
    case noDelegateConfigured
    case delegateFreedBeforeCallback
    case unableToSetFormat(CInt, Format)
    case unableToAddFilter(CInt, Filter)
    case unableToWriteEntryHeader(CInt)
    case unableToWriteData(CLong)
    case unableToCloseArchive(CInt)
    case unableToOpenArchive(CInt)
    case unableToSetOption(CInt)
    case failedToSetLocale(locales: [String])
    case failedToGetProperty(String, URLResourceKey)
    case failedToDetectFilter
    case failedToDetectFormat
    case failedToExtractArchive(String)

    /// Description of the error
    public var description: String {
        switch self {
        case .unableToCreateArchive:
            return "unable to create an archive."
        case .noUnderlyingArchive:
            return "no underlying archive was provided."
        case .noArchiveInCallback:
            return "no archive was provided in the callback."
        case .noDelegateConfigured:
            return "no delegate was configured."
        case .delegateFreedBeforeCallback:
            return "the delegate was freed before the callback was invoked."
        case .unableToSetFormat(let code, let name):
            return "unable to set the archive format \(name), code \(code)"
        case .unableToAddFilter(let code, let name):
            return "unable to set the archive filter \(name), code \(code)"
        case .unableToWriteEntryHeader(let code):
            return "unable to write the entry header to the archive, code \(code)"
        case .unableToWriteData(let code):
            return "unable to write data to the archive, code \(code)"
        case .unableToCloseArchive(let code):
            return "unable to close the archive, code \(code)"
        case .unableToOpenArchive(let code):
            return "unable to open the archive, code \(code)"
        case .unableToSetOption(_):
            return "unable to set an option on the archive."
        case .failedToSetLocale(let locales):
            return "failed to set locale to \(locales)"
        case .failedToGetProperty(let path, let propertyName):
            return "failed to read property \(propertyName) from file at path \(path)"
        case .failedToDetectFilter:
            return "failed to detect filter from archive."
        case .failedToDetectFormat:
            return "failed to detect format from archive."
        case .failedToExtractArchive(let reason):
            return "failed to extract archive: \(reason)"
        }
    }
}

public struct LibArchiveError: Error {
    public let source: ArchiveError
    public let description: String
}

func wrap(_ f: @autoclosure () -> CInt, _ e: (CInt) -> ArchiveError, underlying: OpaquePointer? = nil) throws {
    let result = f()
    guard result == ARCHIVE_OK else {
        let error = e(result)
        guard let underlying = underlying,
            let description = archive_error_string(underlying).map(String.init(cString:))
        else {
            throw error
        }
        throw LibArchiveError(source: error, description: description)
    }
}
