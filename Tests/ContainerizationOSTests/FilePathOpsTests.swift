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
import Testing

@testable import ContainerizationOS

struct FilePathOpsTests {
    @Test("absolutePath returns absolute inputs unchanged")
    func absolutePathPreservesAbsolutePath() {
        let absolute = FilePath("/tmp/containerization/file.tar")
        let resolved = FilePathOps.absolutePath(absolute)

        #expect(resolved == absolute)
    }

    @Test("absolutePath resolves relative paths against cwd and normalizes lexically")
    func absolutePathResolvesRelativePath() {
        let relative = FilePath("./images/../image.tar")
        let expected = FilePath(FileManager.default.currentDirectoryPath)
            .appending(relative.components)
            .lexicallyNormalized()
        let resolved = FilePathOps.absolutePath(relative)

        #expect(resolved == expected)
        #expect(resolved.isAbsolute)
    }
}
