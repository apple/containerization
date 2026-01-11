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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

public struct WriteFileFlags {
    public var createParentDirectories = false
    public var append = false
    public var create = false
}

/// A protocol for the agent running inside a virtual machine. If an operation isn't
/// supported the implementation MUST return a ContainerizationError with a code of
/// `.unsupported`.
public protocol VirtualMachineAgent: Sendable {
    /// Perform a platform specific standard setup
    /// of the runtime environment.
    func standardSetup() async throws
    /// Close any resources held by the agent.
    func close() async throws

    // POSIX-y
    func getenv(key: String) async throws -> String
    func setenv(key: String, value: String) async throws
    func mount(_ mount: ContainerizationOCI.Mount) async throws
    func umount(path: String, flags: Int32) async throws
    func mkdir(path: String, all: Bool, perms: UInt32) async throws
    @discardableResult
    func kill(pid: Int32, signal: Int32) async throws -> Int32
    func sync() async throws
    func writeFile(path: String, data: Data, flags: WriteFileFlags, mode: UInt32) async throws

    // File transfer

    /// Copy a file from the host into the guest.
    func copyIn(
        from source: URL,
        to destination: URL,
        mode: UInt32,
        createParents: Bool,
        chunkSize: Int,
        progress: ProgressHandler?
    ) async throws

    /// Copy a file from the guest to the host.
    func copyOut(
        from source: URL,
        to destination: URL,
        createParents: Bool,
        chunkSize: Int,
        progress: ProgressHandler?
    ) async throws

    // Process lifecycle
    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        ociRuntimePath: String?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws
    func startProcess(id: String, containerID: String?) async throws -> Int32
    func signalProcess(id: String, containerID: String?, signal: Int32) async throws
    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws
    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> ExitStatus
    func deleteProcess(id: String, containerID: String?) async throws
    func closeProcessStdin(id: String, containerID: String?) async throws

    // Networking
    func up(name: String, mtu: UInt32?) async throws
    func down(name: String) async throws
    func addressAdd(name: String, ipv4Address: CIDRv4) async throws
    func routeAddDefault(name: String, ipv4Gateway: IPv4Address) async throws
    func configureDNS(config: DNS, location: String) async throws
    func configureHosts(config: Hosts, location: String) async throws

    // Container statistics
    func containerStatistics(containerIDs: [String]) async throws -> [ContainerStatistics]
}

extension VirtualMachineAgent {
    public func closeProcessStdin(id: String, containerID: String?) async throws {
        throw ContainerizationError(.unsupported, message: "closeProcessStdin")
    }

    public func configureHosts(config: Hosts, location: String) async throws {
        throw ContainerizationError(.unsupported, message: "configureHosts")
    }

    public func writeFile(path: String, data: Data, flags: WriteFileFlags, mode: UInt32) async throws {
        throw ContainerizationError(.unsupported, message: "writeFile")
    }

    public func containerStatistics(containerIDs: [String]) async throws -> [ContainerStatistics] {
        throw ContainerizationError(.unsupported, message: "containerStatistics")
    }

    public func sync() async throws {
        throw ContainerizationError(.unsupported, message: "sync")
    }

    public func copyIn(
        from source: URL,
        to destination: URL,
        mode: UInt32,
        createParents: Bool,
        chunkSize: Int,
        progress: ProgressHandler?
    ) async throws {
        throw ContainerizationError(.unsupported, message: "copyIn")
    }

    public func copyOut(
        from source: URL,
        to destination: URL,
        createParents: Bool,
        chunkSize: Int,
        progress: ProgressHandler?
    ) async throws {
        throw ContainerizationError(.unsupported, message: "copyOut")
    }
}
