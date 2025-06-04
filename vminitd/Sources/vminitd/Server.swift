//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Logging
import Musl
import NIOCore
import NIOPosix

final class Initd: Sendable {
    let log: Logger
    let state: State
    let group: MultiThreadedEventLoopGroup

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

    init(log: Logger, group: MultiThreadedEventLoopGroup) {
        self.log = log
        self.group = group
        self.state = State()
    }

    func serve(port: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            log.debug("starting process supervisor")

            await ProcessSupervisor.default.setLog(self.log)
            await ProcessSupervisor.default.ready()

            log.debug(
                "booting grpc server on vsock",
                metadata: [
                    "port": "\(port)"
                ])

            let server = GRPCServer(
                transport: .http2NIOPosix(
                    address: .vsock(contextID: .any, port: .init(port)),
                    transportSecurity: .plaintext
                ),
                services: [self]
            )

            log.info(
                "grpc api serving on vsock",
                metadata: [
                    "port": "\(port)"
                ])

            group.addTask { try await server.serve() }

            try await group.next()
            group.cancelAll()
        }
    }
}
