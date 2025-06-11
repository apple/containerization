//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

import ContainerizationOCI
import Foundation

/// A protocol for the agent running inside a virtual machine. If an operation isn't
/// supported the implementation MUST return a ContainerizationError with a code of
/// `.unsupported`.
public protocol VirtualMachineAgent: Sendable {
    /// Perform a platform specific standard setup
    /// of the runtime environment.
    func standardSetup() async throws
    /// Close any resources held by the agent.
    func close() async throws

    // POSIX
    func getenv(key: String) async throws -> String
    func setenv(key: String, value: String) async throws
    func mount(_ mount: ContainerizationOCI.Mount) async throws
    func umount(path: String, flags: Int32) async throws
    func mkdir(path: String, all: Bool, perms: UInt32) async throws
    @discardableResult
    func kill(pid: Int32, signal: Int32) async throws -> Int32

    // Process lifecycle
    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws
    func startProcess(id: String, containerID: String?) async throws -> Int32
    func signalProcess(id: String, containerID: String?, signal: Int32) async throws
    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws
    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> Int32
    func deleteProcess(id: String, containerID: String?) async throws

    // Networking
    func up(name: String) async throws
    func down(name: String) async throws
    func addressAdd(name: String, address: String) async throws
    func routeAddDefault(name: String, gateway: String) async throws
    func configureDNS(config: DNS, location: String) async throws
}
