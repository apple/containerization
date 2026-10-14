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
/// Options for the `virtiofsd` processes that serve a cloud-hypervisor VM's
/// virtio-fs shares.
///
/// Every field defaults to virtiofsd's own default, so a default value passes
/// no extra flag.
public struct VirtiofsdOptions: Sendable, Equatable {
    /// The virtiofsd `--cache` policy.
    public enum CachePolicy: String, Sendable, CaseIterable {
        case auto
        case always
        case never
        case metadata
    }

    /// The `--cache` policy. Nil passes no flag, and virtiofsd uses `auto`.
    ///
    /// With `.never` and `.metadata`, virtiofsd opens files with direct I/O.
    /// A guest then refuses a shared mmap of such a file (ENODEV) unless
    /// virtiofsd allows it, so these policies also pass `--allow-mmap`.
    public var cache: CachePolicy?
    /// The `--thread-pool-size`. Nil passes no flag, and virtiofsd serves
    /// requests on the queue thread (a pool size of 0).
    public var threadPoolSize: Int?
    /// Pass `--allow-direct-io`, so that a guest O_DIRECT open reaches the host
    /// file instead of being dropped.
    public var allowDirectIO: Bool

    public init(cache: CachePolicy? = nil, threadPoolSize: Int? = nil, allowDirectIO: Bool = false) {
        self.cache = cache
        self.threadPoolSize = threadPoolSize
        self.allowDirectIO = allowDirectIO
    }

    /// The virtiofsd flags for these options.
    var arguments: [String] {
        var arguments: [String] = []
        if allowDirectIO {
            arguments.append("--allow-direct-io")
        }
        if let cache {
            arguments.append(contentsOf: ["--cache", cache.rawValue])
            if cache == .never || cache == .metadata {
                arguments.append("--allow-mmap")
            }
        }
        if let threadPoolSize {
            arguments.append("--thread-pool-size=\(threadPoolSize)")
        }
        return arguments
    }
}
#endif
