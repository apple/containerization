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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#else
#error("retryingSyscall not supported on this platform.")
#endif

/// Helper type to deal with running system calls.
public struct Syscall {
    /// Retry a syscall on EINTR.
    public static func retrying<T: FixedWidthInteger>(_ closure: () -> T) -> T {
        while true {
            let res = closure()
            if res == -1 && errno == EINTR {
                continue
            }
            return res
        }
    }
}
