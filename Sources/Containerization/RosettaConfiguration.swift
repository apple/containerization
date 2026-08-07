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

import Foundation

/// Configuration for Rosetta x86_64 emulation in Linux virtual machines.
public struct RosettaConfiguration: Equatable, Sendable {
    /// Translation caching configuration used by Rosetta.
    public enum CachingOptions: Equatable, Sendable {
        /// Use Virtualization.framework's default Unix domain socket.
        case defaultUnixSocket
        /// Use a Unix domain socket at the provided guest path.
        case unixSocket(String)
        /// Use a Linux abstract socket with the provided name.
        case abstractSocket(String)
    }

    /// Virtualization.framework's default Rosetta cache socket path.
    public static let defaultUnixSocketPath = "/run/rosettad/rosetta.sock"

    /// Translation caching configuration. Set to `nil` to leave caching disabled.
    public var cachingOptions: CachingOptions?

    public init(cachingOptions: CachingOptions? = .defaultUnixSocket) {
        self.cachingOptions = cachingOptions
    }

    /// Rosetta enabled with the default translation cache.
    public static let cached = RosettaConfiguration()

    /// Rosetta enabled without translation caching.
    public static let uncached = RosettaConfiguration(cachingOptions: nil)
}

extension RosettaConfiguration.CachingOptions {
    var unixSocketPath: String? {
        switch self {
        case .defaultUnixSocket:
            RosettaConfiguration.defaultUnixSocketPath
        case .unixSocket(let path):
            path
        case .abstractSocket:
            nil
        }
    }

    var unixSocketDirectoryPath: String? {
        guard let path = unixSocketPath else {
            return nil
        }
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != "." else {
            return nil
        }
        return directory
    }
}
