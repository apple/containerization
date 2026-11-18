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

import ContainerizationError
import Testing

@testable import Containerization

#if os(macOS)
struct VZBalloonTargetTests {
    private let mib: UInt64 = 1 << 20
    private var configured: UInt64 { 1024 * mib }
    private var minimum: UInt64 { 256 * mib }

    private func validate(_ size: UInt64) throws {
        try VZVirtualMachineInstance.validateBalloonTarget(size, configured: configured, minimum: minimum)
    }

    @Test func acceptsMinimumAndMaximum() throws {
        try validate(minimum)
        try validate(configured)
        try validate(512 * mib)
    }

    @Test func rejectsSizeNotMultipleOfMiB() {
        #expect(throws: ContainerizationError.self) { try validate(512 * mib + 1) }
    }

    @Test func rejectsSizeBelowMinimum() {
        #expect(throws: ContainerizationError.self) { try validate(minimum - mib) }
    }

    @Test func rejectsSizeAboveConfiguredMemory() {
        #expect(throws: ContainerizationError.self) { try validate(configured + mib) }
    }

    @Test func configuredMemoryRoundsUpToMiB() {
        var config = VZVirtualMachineInstance.Configuration()
        config.memoryInBytes = 512 * mib + 1
        #expect(config.vzMemorySize == 513 * mib)
        config.memoryInBytes = 512 * mib
        #expect(config.vzMemorySize == 512 * mib)
    }
}
#endif
