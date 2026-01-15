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

import ContainerizationExtras
import Foundation

internal func createTemporaryDirectory(baseName: String) -> URL? {
    let url = FileManager.default.uniqueTemporaryDirectory().appendingPathComponent(
        "\(baseName).XXXXXX")

    var path = url.absoluteURL.path
    return path.withUTF8 { utf8Bytes in
        var mutablePath = Array(utf8Bytes) + [0]
        return mutablePath.withUnsafeMutableBufferPointer { buffer -> URL? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            mkdtemp(baseAddress)
            let resultPath = String(decoding: buffer[..<(buffer.count - 1)], as: UTF8.self)
            return URL(fileURLWithPath: resultPath, isDirectory: true)
        }
    }
}
