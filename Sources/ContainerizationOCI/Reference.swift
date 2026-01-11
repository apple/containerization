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

import ContainerizationError
import Foundation

private let referenceTotalLengthMax = 255
private let nameTotalLengthMax = 127
private let legacyDockerRegistryHost = "docker.io"
private let dockerRegistryHost = "registry-1.docker.io"
private let defaultDockerRegistryRepo = "library"
private let defaultTag = "latest"

/// A Reference is composed of the various parts of an OCI image reference.
/// For example:
///     let imageReference = "my-registry.com/repository/image:tag2"
///     let reference = Reference.parse(imageReference)
///     print(reference.domain!) // gives us "my-registry.com"
///     print(reference.name) // gives us "my-registry.com/repository/image"
///     print(reference.path) // gives us "repository/image"
///     print(reference.tag!) // gives us "tag2"
///     print(reference.digest) // gives us "nil"
public class Reference: CustomStringConvertible {
    private var _domain: String?
    public var domain: String? {
        _domain
    }
    public var resolvedDomain: String? {
        if let d = _domain {
            return Self.resolveDomain(domain: d)
        }
        return nil
    }

    private var _path: String
    public var path: String {
        _path
    }

    private var _tag: String?
    public var tag: String? {
        _tag
    }

    private var _digest: String?
    public var digest: String? {
        _digest
    }

    public var name: String {
        if let domain, !domain.isEmpty {
            return "\(domain)/\(path)"
        }
        return path
    }

    public var description: String {
        if let tag {
            return "\(name):\(tag)"
        }
        if let digest {
            return "\(name)@\(digest)"
        }
        return name
    }

    static let identifierPattern = "([a-f0-9]{64})"

    static let domainPattern = {
        let domainNameComponent = "(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])"
        let optionalPort = "(?::[0-9]+)?"
        let ipv6address = "\\[(?:[a-fA-F0-9:]+)\\]"
        let domainName = "\(domainNameComponent)(?:\\.\(domainNameComponent))*"
        let host = "(?:\(domainName)|\(ipv6address))"
        let domainAndPort = "\(host)\(optionalPort)"
        return domainAndPort
    }()

    static let pathPattern = "(?<path>(?:[a-z0-9]+(?:[._]|__|-|/)?)*[a-z0-9]+)"
    static let tagPattern = "(?::(?<tag>[\\w][\\w.-]{0,127}))?(?:@(?<digest>sha256:[0-9a-fA-F]{64}))?"
    static let pathTagPattern = "\(pathPattern)\(tagPattern)"

    public init(path: String, domain: String? = nil, tag: String? = nil, digest: String? = nil) throws {
        if let domain, !domain.isEmpty {
            self._domain = domain
        }

        self._path = path
        self._tag = tag
        self._digest = digest
    }

    public static func parse(_ s: String) throws -> Reference {
        if s.count > referenceTotalLengthMax {
            throw ContainerizationError(.invalidArgument, message: "reference length \(s.count) greater than \(referenceTotalLengthMax)")
        }

        let identifierRegex = try Regex(Self.identifierPattern)
        guard try identifierRegex.wholeMatch(in: s) == nil else {
            throw ContainerizationError(.invalidArgument, message: "cannot specify 64 byte hex string as reference")
        }

        let (domain, remainder) = try Self.parseDomain(from: s)
        let constructedRawReference: String = remainder
        if let domain {
            let domainRegex = try Regex(domainPattern)
            guard try domainRegex.wholeMatch(in: domain) != nil else {
                throw ContainerizationError(.invalidArgument, message: "invalid domain \(domain) for reference \(s)")
            }
        }
        let fields = try constructedRawReference.matches(regex: pathTagPattern)
        guard let path = fields["path"] else {
            throw ContainerizationError(.invalidArgument, message: "cannot parse path for reference \(s)")
        }

        let ref = try Reference(path: path, domain: domain)
        if ref.name.count > nameTotalLengthMax {
            throw ContainerizationError(.invalidArgument, message: "repo length \(ref.name.count) greater than \(nameTotalLengthMax)")
        }

        // Extract tag and digest
        let tag = fields["tag"] ?? ""
        let digest = fields["digest"] ?? ""

        if !digest.isEmpty {
            return try ref.withDigest(digest)
        } else if !tag.isEmpty {
            return try ref.withTag(tag)
        }
        return ref
    }

    private static func parseDomain(from s: String) throws -> (domain: String?, remainder: String) {
        var domain: String? = nil
        var path: String = s
        let charset = CharacterSet(charactersIn: ".:")
        let splits = s.split(separator: "/", maxSplits: 1)
        guard splits.count == 2 else {
            if s.starts(with: "localhost") {
                return (s, "")
            }
            return (nil, s)
        }
        let _domain = String(splits[0])
        let _path = String(splits[1])
        if _domain.starts(with: "localhost") || _domain.rangeOfCharacter(from: charset) != nil {
            domain = _domain
            path = _path
        }
        return (domain, path)
    }

    public static func withName(_ name: String) throws -> Reference {
        if name.count > nameTotalLengthMax {
            throw ContainerizationError(.invalidArgument, message: "name length \(name.count) greater than \(nameTotalLengthMax)")
        }
        let fields = try name.matches(regex: Self.domainPattern)
        // Extract domain and path
        let domain = fields["domain"] ?? ""
        let path = fields["path"] ?? ""

        if domain.isEmpty || path.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "image reference domain or path is empty")
        }

        return try Reference(path: path, domain: domain)
    }

    public func withTag(_ tag: String) throws -> Reference {
        var tag = tag
        if !tag.starts(with: ":") {
            tag = ":" + tag
        }
        let fields = try tag.matches(regex: Self.tagPattern)
        tag = fields["tag"] ?? ""

        if tag.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "invalid format for image reference, missing tag")
        }
        return try Reference(path: self.path, domain: self.domain, tag: tag)
    }

    public func withDigest(_ digest: String) throws -> Reference {
        var digest = digest
        if !digest.starts(with: "@") {
            digest = "@" + digest
        }
        let fields = try digest.matches(regex: Self.tagPattern)
        digest = fields["digest"] ?? ""

        if digest.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "invalid format for image reference, missing digest")
        }
        return try Reference(path: self.path, domain: self.domain, digest: digest)
    }

    private static func splitDomain(_ name: String) -> (domain: String, path: String) {
        let parts = name.split(separator: "/")
        guard parts.count == 2 else {
            return ("", name)
        }
        return (String(parts[0]), String(parts[1]))
    }

    /// Normalize the reference object.
    /// Normalization is useful in cases where the reference object is to be used to
    /// fetch/push an image from/to a remote registry.
    /// It does the following:
    /// - Adds a default tag of "latest" if the reference had no tag/digest set.
    /// - If the domain is "registry-1.docker.io" or "docker.io" and the path has no repository set,
    ///   it adds a default "library/" repository name.
    public func normalize() {
        if let domain = self.domain, domain == dockerRegistryHost || domain == legacyDockerRegistryHost {
            // Check if the image is being referenced by a named tag.
            // If it is, and a repository is not specified, prefix it with "library/".
            // This needs to be done only if we are using the Docker registry.
            if !self.path.contains("/") {
                self._path = "\(defaultDockerRegistryRepo)/\(self._path)"
            }
        }
        let identifier = self._tag ?? self._digest
        if identifier == nil {
            // If the user did not specify a tag or a digest for the reference, set the tag to "latest".
            self._tag = defaultTag
        }
    }

    public static func resolveDomain(domain: String) -> String {
        if domain == legacyDockerRegistryHost {
            return dockerRegistryHost
        }
        return domain
    }
}

extension String {
    func matches(regex: String) throws -> [String: String] {
        do {
            let regex = try NSRegularExpression(pattern: regex, options: [])
            let nsRange = NSRange(self.startIndex..<self.endIndex, in: self)
            guard let match = regex.firstMatch(in: self, options: [], range: nsRange), match.range == nsRange else {
                throw ContainerizationError(.invalidArgument, message: "invalid format for image reference")
            }
            var results = [String: String]()
            for name in try regex.captureGroupNames() {
                if let range = Range(match.range(withName: name), in: self) {
                    results[name] = String(self[range])
                }
            }
            return results
        } catch {
            throw error
        }
    }
}

extension NSRegularExpression {
    func captureGroupNames() throws -> [String] {
        let pattern = self.pattern
        let regex = try NSRegularExpression(pattern: "\\(\\?<(\\w+)>", options: [])
        let nsRange = NSRange(pattern.startIndex..<pattern.endIndex, in: pattern)
        let matches = regex.matches(in: pattern, options: [], range: nsRange)
        return matches.map {
            String(pattern[Range($0.range(at: 1), in: pattern)!])
        }
    }
}
