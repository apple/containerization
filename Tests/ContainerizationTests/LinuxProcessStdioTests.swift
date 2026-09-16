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
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Synchronization
import Testing

@testable import Containerization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct LinuxProcessStdioTests {
    private static let stdoutPort: UInt32 = 0x1000_0000

    /// The guest is late, so the host's dial-back window expires first. The
    /// error the caller sees must be the host's own timeout, naming the stream
    /// and port — not the guest's `ECONNRESET`, which is only a consequence of
    /// the host having stopped listening. Reporting the guest's symptom sent a
    /// downstream consumer hunting a phantom port-allocator bug for weeks.
    @Test func reportsTheHostTimeoutRatherThanTheGuestsReset() async throws {
        let allocator = VsockPortAllocator(base: Self.stdoutPort)
        let vm = StubVirtualMachineInstance()
        let agent = StubVirtualMachineAgent(onCreateProcess: {
            // The guest gets to its connect(2) after the host gave up, and
            // cloud-hypervisor answers it with a reset. This used to be the
            // only thing the caller was ever told. The delay is far longer
            // than the 1s dial-back window below so the ordering can't invert
            // under a loaded CI machine's scheduling; it is cancelled as soon
            // as the timeout wins, so it costs nothing.
            try await Task.sleep(for: .seconds(60))
            throw ContainerizationError(
                .internalError,
                message: "createProcess: socket: error could not connect to socket 2:268435456 (Connection reset by peer)"
            )
        })

        let stdio = IOUtil.setup(portAllocator: allocator, stdin: nil, stdout: DiscardWriter(), stderr: nil)
        let process = LinuxProcess(
            "late-guest",
            containerID: "c",
            spec: Self.spec(),
            io: stdio,
            portAllocator: allocator,
            ociRuntimePath: nil,
            agent: agent,
            vm: vm,
            logger: nil,
            stdioTimeoutSeconds: 1
        )

        do {
            try await process.start()
            Issue.record("start() should have failed")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.timeout))
            #expect(error.message.contains("guest did not dial back for stdout"))
            #expect(error.message.contains("vsock port \(Self.stdoutPort)"))
            #expect(error.message.contains("within 1s"))
            #expect(!"\(error)".contains("Connection reset by peer"))
        }
    }

    /// A `createProcess` failure that has nothing to do with stdio must still
    /// be reported as itself, and promptly — not swallowed by, or made to wait
    /// out, the dial-back window.
    @Test func reportsCreateProcessFailureWhenItComesFirst() async throws {
        let allocator = VsockPortAllocator(base: Self.stdoutPort)
        let vm = StubVirtualMachineInstance()
        let agent = StubVirtualMachineAgent(onCreateProcess: {
            throw ContainerizationError(.invalidArgument, message: "no such executable")
        })

        let stdio = IOUtil.setup(portAllocator: allocator, stdin: nil, stdout: DiscardWriter(), stderr: nil)
        let process = LinuxProcess(
            "bad-spec",
            containerID: "c",
            spec: Self.spec(),
            io: stdio,
            portAllocator: allocator,
            ociRuntimePath: nil,
            agent: agent,
            vm: vm,
            logger: nil,
            stdioTimeoutSeconds: 300
        )

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await process.start()
            Issue.record("start() should have failed")
        } catch let error as ContainerizationError {
            #expect(error.message.contains("no such executable"))
        }
        // Must not have waited out the dial-back window: a correct start()
        // cancels the stdio wait as soon as createProcess fails. The bound is
        // deliberately far from both ends — a whole parallel test suite's
        // scheduling delay is seconds, and the regression would be 300 — so
        // this measures cancellation, not the CI machine's load.
        #expect(clock.now - started < .seconds(60))
    }

    /// The happy path, plus the port accounting: a deleted process gives its
    /// stdio ports back, which is what lets a pre-bound pool serve an
    /// unbounded number of sequential processes.
    @Test func releasesPortsOnDeleteSoTheyCanBeReused() async throws {
        let allocator = VsockPortAllocator(base: Self.stdoutPort)
        let vm = StubVirtualMachineInstance()

        var pipeFds: [Int32] = [-1, -1]
        let rc = pipeFds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return pipe(base)
        }
        try #require(rc == 0)
        let writeEnd = pipeFds[1]
        let readEnd = pipeFds[0]
        defer { _ = close(writeEnd) }

        let agent = StubVirtualMachineAgent(
            pid: 4242,
            onCreateProcess: {
                // Stand in for the guest dialing back on the stdout port.
                guard let listener = vm.listener(forPort: Self.stdoutPort) else {
                    throw ContainerizationError(.internalError, message: "no listener for the stdout port")
                }
                _ = listener.yield(FileHandle(fileDescriptor: readEnd, closeOnDealloc: false))
            }
        )

        let stdio = IOUtil.setup(portAllocator: allocator, stdin: nil, stdout: DiscardWriter(), stderr: nil)

        let process = LinuxProcess(
            "good",
            containerID: "c",
            spec: Self.spec(),
            io: stdio,
            portAllocator: allocator,
            ociRuntimePath: nil,
            agent: agent,
            vm: vm,
            logger: nil,
            stdioTimeoutSeconds: 30
        )

        try await process.start()
        #expect(process.pid == 4242)

        try await process.delete()
        #expect(allocator.allocate() == Self.stdoutPort)
    }

    private static func spec() -> ContainerizationOCI.Spec {
        var spec = ContainerizationOCI.Spec()
        spec.process = LinuxProcessConfiguration(arguments: ["/bin/true"]).toOCI()
        return spec
    }
}

// MARK: - Stubs

private final class DiscardWriter: Writer {
    func write(_ data: Data) throws {}
    func close() throws {}
}

/// Minimal `VirtualMachineInstance` that hands out real `VsockListener`s and
/// keeps them addressable, so a stub agent can play the guest's dial-back.
private final class StubVirtualMachineInstance: VirtualMachineInstance {
    typealias Agent = StubVirtualMachineAgent

    private let listeners = Mutex<[UInt32: VsockListener]>([:])

    var state: VirtualMachineInstanceState { .running }
    var mounts: [String: [AttachedFilesystem]] { [:] }

    func listener(forPort port: UInt32) -> VsockListener? {
        listeners.withLock { $0[port] }
    }

    func listen(_ port: UInt32) throws -> VsockListener {
        let listener = VsockListener(port: port) { _ in }
        listeners.withLock { $0[port] = listener }
        return listener
    }

    func dialAgent() async throws -> StubVirtualMachineAgent {
        throw ContainerizationError(.unsupported, message: "dialAgent")
    }
    func dial(_ port: UInt32) async throws -> FileHandle {
        throw ContainerizationError(.unsupported, message: "dial")
    }
    func start() async throws {}
    func stop() async throws {}
}

/// `VirtualMachineAgent` stub whose `createProcess` is injectable so a test
/// can decide whether the guest dials back, is late, or fails outright.
/// Everything the tests don't touch is a no-op.
private final class StubVirtualMachineAgent: VirtualMachineAgent {
    private let pid: Int32
    private let onCreateProcess: (@Sendable () async throws -> Void)?

    init(pid: Int32 = 1, onCreateProcess: (@Sendable () async throws -> Void)? = nil) {
        self.pid = pid
        self.onCreateProcess = onCreateProcess
    }

    func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        ociRuntimePath: String?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws {
        try await onCreateProcess?()
    }

    func startProcess(id: String, containerID: String?) async throws -> Int32 { pid }
    func deleteProcess(id: String, containerID: String?) async throws {}
    func close() async throws {}

    func standardSetup() async throws {}
    func filesystemOperation(operation: FilesystemOperation, path: String, containerID: String?) async throws {}
    func getenv(key: String) async throws -> String { "" }
    func setenv(key: String, value: String) async throws {}
    func mount(_ mount: ContainerizationOCI.Mount) async throws {}
    func umount(path: String, flags: Int32) async throws {}
    func mkdir(path: String, all: Bool, perms: UInt32) async throws {}
    @discardableResult
    func kill(pid: Int32, signal: Int32) async throws -> Int32 { 0 }
    func signalProcess(id: String, containerID: String?, signal: Int32) async throws {}
    func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws {}
    func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64?) async throws -> Containerization.ExitStatus {
        Containerization.ExitStatus(exitCode: 0)
    }
    func up(name: String, mtu: UInt32?) async throws {}
    func down(name: String) async throws {}
    func addressAdd(name: String, address: InterfaceAddress) async throws {}
    func routeAddLink(name: String, route: LinkRoute) async throws {}
    func routeAddDefault(name: String, route: DefaultRoute) async throws {}
    func configureDNS(config: DNS, location: String) async throws {}
}
