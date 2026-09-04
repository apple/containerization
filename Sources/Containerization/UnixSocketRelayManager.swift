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
import Foundation
import Logging

package actor UnixSocketRelayManager {
    private struct RelayKey: Hashable {
        let owner: String?
        let socketID: String
    }

    private struct ManagedRelay {
        let socket: UnixSocketConfiguration
        let relay: UnixSocketRelay
    }

    private let vm: any VirtualMachineInstance
    private var relays: [RelayKey: ManagedRelay]
    private let log: Logger?

    init(vm: any VirtualMachineInstance, log: Logger? = nil) {
        self.vm = vm
        self.relays = [:]
        self.log = log
    }
}

extension UnixSocketRelayManager {
    func start(port: UInt32, socket: UnixSocketConfiguration, owner: String? = nil) async throws {
        let key = RelayKey(owner: owner, socketID: socket.id)
        guard relays[key] == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "socket relay \(socket.id) already started"
            )
        }

        let relay = try UnixSocketRelay(
            port: port,
            socket: socket,
            vm: vm,
            log: log
        )

        do {
            relays[key] = ManagedRelay(socket: socket, relay: relay)
            try await relay.start()
        } catch {
            relays.removeValue(forKey: key)
            throw error
        }
    }

    func stop(socket: UnixSocketConfiguration, owner: String? = nil) async throws {
        let key = RelayKey(owner: owner, socketID: socket.id)
        guard let storedRelay = relays.removeValue(forKey: key) else {
            throw ContainerizationError(
                .notFound,
                message: "failed to stop socket relay"
            )
        }
        try storedRelay.relay.stop()
    }

    func sockets(owner: String) -> [UnixSocketConfiguration] {
        relays.compactMap { key, relay in
            key.owner == owner ? relay.socket : nil
        }
    }

    func stopAll(owner: String) async throws {
        let keys = relays.keys.filter { $0.owner == owner }
        try stop(keys: keys)
    }

    func stopAll() async throws {
        try stop(keys: Array(relays.keys))
    }

    private func stop(keys: [RelayKey]) throws {
        let relays = keys.compactMap { self.relays.removeValue(forKey: $0) }

        var firstError: Error?
        for relay in relays {
            do {
                try relay.relay.stop()
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }
}
