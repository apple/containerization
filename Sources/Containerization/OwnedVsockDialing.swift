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

import ContainerizationOS
import Foundation

/// Built-in backends establish ownership before publishing a Foundation handle.
package protocol OwnedVsockDialing: VirtualMachineInstance {
    func dialOwned(_ port: UInt32) async throws -> DescriptorTransfer
}

package func exportVsockHandle(_ descriptor: consuming DescriptorTransfer, blocking: Bool? = nil, closeOnDealloc: Bool = false) throws -> FileHandle {
    let owner = descriptor.takeOwner()
    do {
        if let blocking {
            let use = try owner.acquire()
            defer { use.end() }
            let flags = fcntl(use.fileDescriptor, F_GETFL)
            guard flags != -1, fcntl(use.fileDescriptor, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK) != -1 else {
                throw POSIXError.fromErrno()
            }
        }
        return FileHandle(fileDescriptor: try owner.release(), closeOnDealloc: closeOnDealloc)
    } catch {
        try? owner.close()
        throw error
    }
}
