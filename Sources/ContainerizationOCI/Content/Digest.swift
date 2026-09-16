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

import ContainerizationError
import Crypto
import Foundation

/// A validated content digest of the form `sha256:<64 lowercase hex characters>`.
///
/// Descriptor digests arrive as free-form strings from remote registries and from
/// on-disk OCI layouts, and they are used as content store path components. An
/// unvalidated value such as `sha256:../../etc/hosts` would therefore escape the
/// store's blob directory, so a digest must be parsed before it reaches the
/// filesystem. ``encoded`` is the only way to obtain a path component from this
/// type, and it is safe by construction.
///
/// Only `sha256` is accepted. The blob layout is hardcoded to `blobs/sha256`
/// (see ``LocalContentStore``) and every producer in the project emits `sha256`,
/// so admitting another algorithm would turn a clear rejection at the boundary
/// into a confusing `notFound` deep inside the store. Uppercase hex is rejected
/// for the same reason it matters on a case-insensitive filesystem: two spellings
/// of one digest must not map to two different blob names.
public struct ParsedDigest: Sendable, Hashable, CustomStringConvertible {
    /// The only digest algorithm this project stores content under.
    public static let algorithm = "sha256"

    private static let prefix = "\(algorithm):"
    private static let encodedLength = 64

    /// The hex encoded hash, without the algorithm prefix. Safe to use as a
    /// single filesystem path component.
    public let encoded: String

    /// The canonical `sha256:<hex>` form.
    public var description: String { "\(Self.prefix)\(self.encoded)" }

    /// Parse a digest that carries its algorithm prefix.
    ///
    /// - Parameter digest: A digest of the form `sha256:<64 lowercase hex characters>`.
    public init(parsing digest: String) throws {
        guard digest.hasPrefix(Self.prefix) else {
            throw ContainerizationError(.invalidArgument, message: "digest \(digest) is not prefixed with \(Self.prefix)")
        }
        try self.init(validating: String(digest.dropFirst(Self.prefix.count)), original: digest)
    }

    /// Parse a digest that may or may not carry its algorithm prefix.
    ///
    /// Content store blobs are named by the hex encoding alone, so lookups reach
    /// the store in both spellings.
    ///
    /// - Parameter component: Either `sha256:<hex>` or a bare `<hex>`.
    public init(parsingPathComponent component: String) throws {
        if component.contains(":") {
            try self.init(parsing: component)
            return
        }
        try self.init(validating: component, original: component)
    }

    /// Bridge from an already trusted, locally computed hash.
    public init(_ digest: SHA256.Digest) {
        self.encoded = digest.encoded
    }

    private init(validating encoded: String, original: String) throws {
        // Validate over UTF-8 rather than Character. Character comparison works on
        // grapheme clusters using Unicode canonical ordering, so a base letter with
        // a combining mark ("b" + U+0308) compares as inside "a"..."f" and would be
        // accepted — 64 graphemes that are not 64 bytes, defeating the one-digest-
        // one-blob-name invariant that also motivates rejecting uppercase.
        let bytes = encoded.utf8
        guard bytes.count == Self.encodedLength else {
            throw ContainerizationError(
                .invalidArgument,
                message: "digest \(original) must encode \(Self.encodedLength) hex characters, got \(bytes.count)")
        }
        guard bytes.allSatisfy(Self.isLowercaseHexDigit) else {
            throw ContainerizationError(.invalidArgument, message: "digest \(original) must only contain lowercase hex characters")
        }
        self.encoded = encoded
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"):
            return true
        default:
            return false
        }
    }

    /// Whether `digest` is a well formed digest, in either spelling.
    public static func isValid(_ digest: String) -> Bool {
        (try? ParsedDigest(parsingPathComponent: digest)) != nil
    }

    /// Resolve this digest to a file path directly beneath `root`.
    ///
    /// A parsed digest cannot traverse, so the containment check is redundant by
    /// construction. It is kept as the single place that turns a digest into a
    /// path, so that a future caller cannot reintroduce an escape without
    /// tripping it.
    ///
    /// The root is resolved once and the child derived from the resolved value.
    /// Resolving the two independently is wrong: `resolvingSymlinksInPath()`
    /// treats existing and non-existent paths differently — it strips a leading
    /// `/private` from one and adds it to the other, and only resolves symlinked
    /// ancestors that exist — so a present blob and an absent one under the same
    /// root would not agree.
    public func path(in root: URL) throws -> URL {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolvedRoot.appendingPathComponent(self.encoded)
        guard path.deletingLastPathComponent().standardizedFileURL.path == resolvedRoot.standardizedFileURL.path else {
            throw ContainerizationError(.invalidArgument, message: "digest \(self) resolves outside of \(resolvedRoot.path)")
        }
        return path
    }
}

extension String {
    /// Validate that the string is a well formed digest and return the hex
    /// encoded portion, which is safe to use as a single path component.
    ///
    /// Prefer this over ``trimmingDigestPrefix`` anywhere the result is used to
    /// build a filesystem path.
    public func validatedDigestEncoding() throws -> String {
        try ParsedDigest(parsingPathComponent: self).encoded
    }
}
