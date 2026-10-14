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
import Foundation
import Testing

@testable import Containerization

struct VirtiofsdOptionsTests {
    private func config(readonly: Bool = false, options: VirtiofsdOptions) -> VirtiofsdProcess.Config {
        VirtiofsdProcess.Config(
            binary: URL(fileURLWithPath: "/usr/bin/virtiofsd"),
            socketPath: URL(fileURLWithPath: "/run/vfs.sock"),
            sharedDir: URL(fileURLWithPath: "/srv/share"),
            readonly: readonly,
            options: options
        )
    }

    @Test func defaultOptionsPassNoExtraFlag() {
        let arguments = VirtiofsdProcess.arguments(config: config(options: .init()), sandboxDisabled: false)
        #expect(arguments == ["--socket-path", "/run/vfs.sock", "--shared-dir", "/srv/share"])
    }

    @Test func sandboxAndReadonlyComeBeforeTheOptions() {
        let options = VirtiofsdOptions(cache: .always, threadPoolSize: 4, allowDirectIO: true)
        let arguments = VirtiofsdProcess.arguments(config: config(readonly: true, options: options), sandboxDisabled: true)
        #expect(
            arguments == [
                "--socket-path", "/run/vfs.sock", "--shared-dir", "/srv/share",
                "--sandbox", "none", "--readonly",
                "--allow-direct-io", "--cache", "always", "--thread-pool-size=4",
            ])
    }

    /// virtiofsd opens files with direct I/O for these policies, so a shared mmap
    /// in the guest needs --allow-mmap.
    @Test(arguments: [VirtiofsdOptions.CachePolicy.never, .metadata])
    func directIOCachePoliciesAllowMmap(cache: VirtiofsdOptions.CachePolicy) {
        #expect(VirtiofsdOptions(cache: cache).arguments == ["--cache", cache.rawValue, "--allow-mmap"])
    }

    @Test(arguments: [VirtiofsdOptions.CachePolicy.auto, .always])
    func cachedPoliciesDoNotAllowMmap(cache: VirtiofsdOptions.CachePolicy) {
        #expect(VirtiofsdOptions(cache: cache).arguments == ["--cache", cache.rawValue])
    }

    @Test func managerRejectsANegativeThreadPoolSize() throws {
        let kernel = Kernel(path: URL(fileURLWithPath: "/dev/null"), platform: .linuxArm)
        let rootfs = Mount.block(format: "ext4", source: "/dev/null", destination: "/")
        let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vfs-opts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        #expect(throws: (any Error).self) {
            _ = try CHVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: rootfs,
                chBinary: URL(fileURLWithPath: "/bin/true"),
                virtiofsdOptions: .init(threadPoolSize: -1),
                runtimeRoot: runtimeRoot
            )
        }
    }
}
#endif
