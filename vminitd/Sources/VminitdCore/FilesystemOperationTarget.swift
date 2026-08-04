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

#if os(Linux)

import Containerization
import Foundation
import LCShim

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

enum FilesystemOperationTarget {
    static func open(rootDescriptor: Int32, path: String) throws -> Int32 {
        try FilesystemOperationPath.validate(path)

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        for _ in 0..<3 {
            let descriptor = path.withCString {
                CZ_openat2_in_root(rootDescriptor, $0, flags)
            }
            if descriptor >= 0 {
                return descriptor
            }
            guard errno == EAGAIN else {
                throw POSIXError.fromErrno()
            }
        }
        throw POSIXError(.EAGAIN)
    }
}

#endif
