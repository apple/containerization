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
import SystemPackage

/// Static utility functions for path operations.
///
/// The type is never instantiated; it exists solely as a namespace.
public struct FilePathOps {
    private init() {}

    /// Returns an absolute version of `path`.
    ///
    /// This is a purely lexical operation: it does not resolve symlinks
    /// and does not access the file system. If `path` is already absolute,
    /// this returns `path` unchanged.
    public static func absolutePath(_ path: FilePath) -> FilePath {
        guard !path.isAbsolute else {
            return path
        }

        return FilePath(FileManager.default.currentDirectoryPath)
            .appending(path.components)
            .lexicallyNormalized()
    }
}
