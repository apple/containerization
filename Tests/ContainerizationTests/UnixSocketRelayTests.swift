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
import ContainerizationOS
import Foundation
import Synchronization
import Testing

@testable import Containerization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct UnixSocketRelayTests {
    private func socketPair() throws -> (connection: FileHandle, peer: FileHandle) {
        var fds: [Int32] = [-1, -1]
        #if canImport(Glibc)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        try #require(socketpair(AF_UNIX, type, 0, &fds) == 0)
        return (
            FileHandle(fileDescriptor: fds[0], closeOnDealloc: false),
            FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        )
    }

    private func waitUntilReadable(_ fd: Int32) async throws {
        while true {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 0)
            if ready == -1 && errno == EINTR { continue }
            try #require(ready >= 0)
            if ready > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func read(from fd: Int32, count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            try await waitUntilReadable(fd)
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let received = Foundation.read(fd, &bytes, bytes.count)
            if received == -1 && (errno == EAGAIN || errno == EINTR) { continue }
            try #require(received >= 0)
            if received == 0 { break }
            result.append(contentsOf: bytes.prefix(received))
        }
        return result
    }

    @Test(.timeLimit(.minutes(1)))
    func refusedConnectionsCloseAndListenerRecovers() async throws {
        let path = URL(filePath: "/tmp/relay-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: path) }
        let type = try UnixType(path: path.path, unlinkExisting: true)
        let unavailable = try Socket(type: type)
        try unavailable.listen()
        try unavailable.close()
        let vm = RelayVirtualMachine()
        let relay = try UnixSocketRelay(
            port: vm.listener.port,
            socket: .init(source: path, destination: path, direction: .into),
            vm: vm
        )
        try await relay.start()
        defer { try? relay.stop() }
        let failures = try (0..<2).map { _ in try socketPair() }
        defer {
            for failure in failures {
                try? failure.connection.close()
                try? failure.peer.close()
            }
        }
        for failure in failures { _ = vm.listener.yield(failure.connection) }
        for failure in failures {
            #expect(try await read(from: failure.peer.fileDescriptor, count: 1).isEmpty)
        }

        let server = try Socket(type: type)
        try server.listen()
        defer { try? server.close() }
        let (connection, peer) = try socketPair()
        defer { try? peer.close() }
        if case .terminated = vm.listener.yield(connection) {
            try? connection.close()
            Issue.record("A failed connection stopped the relay listener")
            return
        }
        try await waitUntilReadable(server.fileDescriptor)
        let host = try server.accept()
        defer { try? host.close() }
        let request = Data("agent request".utf8)
        try peer.write(contentsOf: request)
        #expect(try await read(from: host.fileDescriptor, count: request.count) == request)
        let response = Data("agent reply".utf8)
        #expect(try host.write(data: response) == response.count)
        #expect(try await read(from: peer.fileDescriptor, count: response.count) == response)
    }

    @Test(.timeLimit(.minutes(1)))
    func refusedDialsCloseAndListenerRecovers() async throws {
        let path = URL(filePath: "/tmp/relay-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: path) }
        let type = try UnixType(path: path.path)
        let vm = RelayVirtualMachine()
        let relay = try UnixSocketRelay(
            port: vm.listener.port,
            socket: .init(source: path, destination: path, direction: .outOf),
            vm: vm
        )
        try await relay.start()
        defer { try? relay.stop() }

        let refused = try Socket(type: type)
        defer { try? refused.close() }
        try refused.connect()
        #expect(try await read(from: refused.fileDescriptor, count: 1).isEmpty)

        let (connection, peer) = try socketPair()
        defer {
            try? peer.close()
            vm.dialConnection.withLock {
                try? $0?.close()
                $0 = nil
            }
        }
        vm.dialConnection.withLock { $0 = connection }
        let host = try Socket(type: type)
        defer { try? host.close() }
        try host.connect()
        let request = Data("guest request".utf8)
        _ = try host.write(data: request)
        #expect(try await read(from: peer.fileDescriptor, count: request.count) == request)
    }
}

private final class RelayVirtualMachine: VirtualMachineInstance {
    typealias Agent = Vminitd

    let listener = VsockListener(port: 1025) { _ in }
    let dialConnection = Mutex<FileHandle?>(nil)
    var state: VirtualMachineInstanceState { .running }
    var mounts: [String: [AttachedFilesystem]] { [:] }

    func listen(_ port: UInt32) throws -> VsockListener { listener }
    func dialAgent() async throws -> Vminitd {
        throw ContainerizationError(.unsupported, message: "dialAgent")
    }
    func dial(_ port: UInt32) async throws -> FileHandle {
        try dialConnection.withLock {
            guard let connection = $0 else { throw POSIXError(.ECONNREFUSED) }
            $0 = nil
            return connection
        }
    }
    func start() async throws {}
    func stop() async throws {}
}
