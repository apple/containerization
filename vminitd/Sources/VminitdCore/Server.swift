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

import Cgroup
import ContainerizationError
import ContainerizationOCI
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Logging
import NIOCore
import NIOPosix

public final class Initd: Sendable {
    static let PID: Int32 = 1

    public actor State {
        private(set) var containers: [String: ManagedContainer] = [:]
        private(set) var rootProcesses: [String: ManagedProcess] = [:]
        var proxies: [String: VsockProxy] = [:]

        public typealias ContainerDeletedHandler = @Sendable (String) async -> Void
        private var onContainerDeleted: [ContainerDeletedHandler] = []

        public func onDelete(_ handler: @escaping ContainerDeletedHandler) {
            onContainerDeleted.append(handler)
        }

        public func get(container id: String) throws -> ManagedContainer {
            guard let ctr = self.containers[id] else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(id) not found"
                )
            }
            return ctr
        }

        func add(container: ManagedContainer) throws {
            guard containers[container.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container \(container.id) already exists"
                )
            }
            containers[container.id] = container
        }

        func add(proxy: VsockProxy) throws {
            guard proxies[proxy.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "proxy \(proxy.id) already exists"
                )
            }
            proxies[proxy.id] = proxy
        }

        func remove(proxy id: String) throws -> VsockProxy {
            guard let proxy = proxies.removeValue(forKey: id) else {
                throw ContainerizationError(
                    .notFound,
                    message: "proxy \(id) does not exist"
                )
            }
            return proxy
        }

        func remove(container id: String) throws {
            guard let _ = containers.removeValue(forKey: id) else {
                throw ContainerizationError(
                    .notFound,
                    message: "container \(id) does not exist"
                )
            }
            let handlers = onContainerDeleted
            Task {
                for handler in handlers {
                    await handler(id)
                }
            }
        }

        static func craftRootBundlePath(id: String) -> URL {
            URL(fileURLWithPath: "/run/vminitd-root").appending(path: id)
        }

        // A sibling of /vminitd: a cgroup holding vminitd cannot delegate controllers to children.
        static func craftRootCgroupPath(id: String) -> URL {
            URL(filePath: "/vminitd-root").appending(path: id)
        }

        func createRootProcess(
            id: String,
            stdio: HostStdio,
            process: ContainerizationOCI.Process,
            resources: ContainerizationOCI.LinuxResources?,
            log: Logger
        ) throws {
            // The id becomes a path component of the bundle and cgroup.
            try ManagedContainer.validate(id: id)

            guard rootProcesses[id] == nil else {
                throw ContainerizationError(.exists, message: "root process \(id) already exists")
            }
            // closeStdin and resize are not routed for root processes, so stdin would never see EOF.
            guard stdio.stdin == nil, !stdio.terminal else {
                throw ContainerizationError(.invalidArgument, message: "root process \(id): stdin and terminal are not supported")
            }

            // Root cgroups outlive delete, so an id is single-use: reuse would inherit stale limits.
            let cgroupPath = Self.craftRootCgroupPath(id: id)
            let cgroupDir = Cgroup2Manager.defaultMountPoint.appending(path: cgroupPath.path)
            guard !FileManager.default.fileExists(atPath: cgroupDir.path) else {
                throw ContainerizationError(.exists, message: "root process id \(id) was already used")
            }

            let cgroup = Cgroup2Manager(group: cgroupPath, logger: log)
            try cgroup.create()

            do {
                try cgroup.toggleAllAvailableControllers(enable: true)
                if let resources {
                    try cgroup.applyResources(resources: resources)
                }

                // A minimal bundle only used to hold the exec's process.json; exec mode does not
                // pivot into rootfs, so no real rootfs is required.
                let bundle = try ContainerizationOCI.Bundle.create(
                    path: Self.craftRootBundlePath(id: id),
                    spec: ContainerizationOCI.Spec(process: process)
                )
                try bundle.createExecSpec(id: id, process: process)
                let managed = try ManagedProcess(
                    id: id,
                    stdio: stdio,
                    bundle: bundle,
                    owningPid: Initd.PID,
                    cgroup: cgroup,
                    log: log
                )
                rootProcesses[id] = managed
            } catch {
                try? FileManager.default.removeItem(at: Self.craftRootBundlePath(id: id))
                try? cgroup.delete()
                throw error
            }
        }

        func startRootProcess(id: String) async throws -> Int32 {
            let managed = try rootProcess(id: id)
            // Route through the supervisor (mirror ManagedContainer.start) so an early-exiting
            // process is reaped and does not become a zombie.
            return try await ProcessSupervisor.default.start(process: managed)
        }

        func waitRootProcess(id: String) async throws -> ContainerExitStatus {
            let managed = try rootProcess(id: id)
            return await managed.wait()
        }

        func killRootProcess(id: String, signal: Int32) async throws {
            try await rootProcess(id: id).kill(signal)
        }

        // Releases bookkeeping only. The process keeps running if alive, and the cgroup, with
        // any process left in it, lives until the VM stops.
        func deleteRootProcess(id: String) async throws {
            let managed = try rootProcess(id: id)

            try await managed.delete()
            try FileManager.default.removeItem(at: Self.craftRootBundlePath(id: id))
            rootProcesses.removeValue(forKey: id)
        }

        private func rootProcess(id: String) throws -> ManagedProcess {
            guard let managed = rootProcesses[id] else {
                throw ContainerizationError(.notFound, message: "root process \(id) not found")
            }
            return managed
        }
    }

    public let log: Logger
    public let state: State
    let group: MultiThreadedEventLoopGroup
    let blockingPool: NIOThreadPool

    public init(log: Logger, group: MultiThreadedEventLoopGroup, blockingPool: NIOThreadPool) {
        self.log = log
        self.group = group
        self.blockingPool = blockingPool
        self.state = State()
    }

    public func serve(port: Int, additionalServices: [any RegistrableRPCService] = []) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            log.debug("starting process supervisor")

            ProcessSupervisor.default.setLog(self.log)
            ProcessSupervisor.default.ready()

            log.info(
                "booting gRPC server on vsock",
                metadata: [
                    "port": "\(port)"
                ])

            let server = GRPCServer(
                transport: .http2NIOPosix(
                    address: .vsock(contextID: .any, port: .init(port)),
                    transportSecurity: .plaintext,
                    eventLoopGroup: self.group
                ),
                services: [self] + additionalServices
            )

            log.info(
                "gRPC API serving on vsock",
                metadata: [
                    "port": "\(port)"
                ])

            group.addTask { try await server.serve() }

            try await group.next()
            log.info("closing gRPC server")
            group.cancelAll()
        }
    }
}

#endif
