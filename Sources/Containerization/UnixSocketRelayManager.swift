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
    private let vm: any VirtualMachineInstance
    private var relays: [String: UnixSocketRelay]
    private let q: DispatchQueue
    private let log: Logger?

    init(vm: any VirtualMachineInstance, log: Logger? = nil) {
        self.vm = vm
        self.relays = [:]
        self.q = DispatchQueue(label: "com.apple.containerization.socket-relay")
        self.log = log
    }
}

extension UnixSocketRelayManager {
    func start(port: UInt32, socket: UnixSocketConfiguration) async throws {
        guard relays[socket.id] == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "socket relay \(socket.id) already started"
            )
        }

        let relay = try UnixSocketRelay(
            port: port,
            socket: socket,
            vm: vm,
            queue: q,
            log: log
        )

        do {
            relays[socket.id] = relay
            try await relay.start()
        } catch {
            relays.removeValue(forKey: socket.id)
        }
    }

    func stop(socket: UnixSocketConfiguration) async throws {
        guard let storedRelay = relays.removeValue(forKey: socket.id) else {
            throw ContainerizationError(
                .notFound,
                message: "failed to stop socket relay"
            )
        }
        try storedRelay.stop()
    }

    func stopAll() async throws {
        for (_, relay) in relays {
            try relay.stop()
        }
    }
}
