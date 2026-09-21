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
import ContainerizationExtras
import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

extension IntegrationSuite {
    /// The bytes the host has actually allocated to `url`, which for a sparse
    /// disk image is what a trim gives back. `stat` rather than
    /// `URL.totalFileAllocatedSize`, which caches its answer in the URL and so
    /// reports the same figure before and after a trim.
    func allocatedBytes(of url: URL) throws -> UInt64 {
        var info = stat()
        guard stat(url.absolutePath(), &info) == 0 else {
            throw IntegrationError.assert(msg: "failed to stat \(url.absolutePath())")
        }
        return UInt64(info.st_blocks) * 512
    }

    /// The trim tests each free 64 MiB before trimming. Insisting on half of
    /// that leaves room for the allocator's granularity while still failing if
    /// the filesystem went untrimmed.
    func requireReclaimed(_ name: String, before: UInt64, after: UInt64) throws {
        guard before >= after + 32.mib() else {
            throw IntegrationError.assert(
                msg: "\(name) kept its blocks after a trim: \(before) bytes allocated before, \(after) after")
        }
    }
}
