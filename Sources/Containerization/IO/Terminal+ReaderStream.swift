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

import ContainerizationOS
@preconcurrency import Dispatch
import Foundation

extension Terminal: ReaderStream {
    public func stream() -> AsyncStream<Data> {
        let fd = self.fileDescriptor
        guard fd >= 0 else {
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue(label: "com.apple.containerization.terminal.reader")
            )

            var buffer = [UInt8](repeating: 0, count: Int(getpagesize()))
            source.setEventHandler {
                let bytesRead = read(fd, &buffer, buffer.count)
                if bytesRead > 0 {
                    continuation.yield(Data(buffer[..<bytesRead]))
                } else {
                    source.cancel()
                }
            }

            source.setCancelHandler {
                continuation.finish()
            }

            continuation.onTermination = { _ in
                source.cancel()
            }

            source.activate()
        }
    }
}

extension Terminal: Writer {}
