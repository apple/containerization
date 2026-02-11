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
import Foundation
import GRPC
import Logging
import NIOCore
import NIOPosix

final class Initd: Sendable {
    actor State {
        var containers: [String: ManagedContainer] = [:]
        var proxies: [String: VsockProxy] = [:]

        func get(container id: String) throws -> ManagedContainer {
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
        }
    }

    let log: Logger
    let state: State
    let group: EventLoopGroup

    init(log: Logger, group: EventLoopGroup) {
        self.log = log
        self.group = group
        self.state = State()
    }

    func serve(port: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            log.debug("starting process supervisor")

            ProcessSupervisor.default.setLog(self.log)
            ProcessSupervisor.default.ready()

            log.info(
                "booting gRPC server on vsock",
                metadata: [
                    "port": "\(port)"
                ])
            let server = try await Server.start(
                configuration: .default(
                    target: .vsockAddress(.init(cid: .any, port: .init(port))),
                    eventLoopGroup: self.group,
                    serviceProviders: [self])
            ).get()
            log.info(
                "gRPC API serving on vsock",
                metadata: [
                    "port": "\(port)"
                ])

            group.addTask {
                try await server.onClose.get()
            }
            try await group.next()
            log.info("closing gRPC server")
            group.cancelAll()
        }
    }
}
