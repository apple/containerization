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

import Foundation

extension Pipe {
    /// Close both sides of the pipe.
    public func close() throws {
        var err: Swift.Error?
        do {
            try self.fileHandleForReading.close()
        } catch {
            err = error
        }
        try self.fileHandleForWriting.close()
        if let err {
            throw err
        }
    }

    /// Ensure that both sides of the pipe are set with O_CLOEXEC.
    public func setCloexec() throws {
        if fcntl(self.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) == -1 {
            throw POSIXError(.init(rawValue: errno)!)
        }
        if fcntl(self.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC) == -1 {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }
}
