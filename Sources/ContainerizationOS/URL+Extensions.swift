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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The `resolvingSymlinksInPath` method of the `URL` struct does not resolve the symlinks
/// for directories under `/private` which include`tmp`, `var` and `etc`
/// hence adding a method to build up on the existing `resolvingSymlinksInPath` that prepends `/private` to those paths
extension URL {
    /// returns the unescaped absolutePath of a URL joined by separator
    func absolutePath(_ separator: String = "/") -> String {
        self.pathComponents
            .joined(separator: separator)
            .dropFirst("/".count)
            .description
    }

    public func resolvingSymlinksInPathWithPrivate() -> URL {
        let url = self.resolvingSymlinksInPath()
        #if os(macOS)
        let parts = url.pathComponents
        if parts.count > 1 {
            if (parts.first == "/") && ["tmp", "var", "etc"].contains(parts[1]) {
                var resolved = URL(filePath: "/private")
                for part in parts[1...] {
                    resolved.append(path: part)
                }
                return resolved
            }
        }
        #endif
        return url
    }

    public var isDirectory: Bool {
        var st = stat()
        guard stat(self.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    public var isSymlink: Bool {
        var st = stat()
        guard lstat(self.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }
}
