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

import Containerization
import Foundation
import Synchronization

/// A Writer that captures output into a Data buffer and optionally streams it.
final class OutputCapture: Writer, Sendable {
    private let storage = Mutex(Data())
    private let streamTo: FileHandle?

    var data: Data {
        storage.withLock { $0 }
    }

    init(streamToStdout: Bool = false, streamToStderr: Bool = false) {
        if streamToStdout {
            self.streamTo = .standardOutput
        } else if streamToStderr {
            self.streamTo = .standardError
        } else {
            self.streamTo = nil
        }
    }

    func write(_ data: Data) throws {
        guard data.count > 0 else { return }
        storage.withLock { $0.append(data) }
        streamTo?.write(data)
    }

    func close() throws {}
}
