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

import Foundation
import SystemPackage

/// Represents a UnixSocket that can be shared into or out of a container/guest.
public struct UnixSocketConfiguration: Sendable {
    // TODO: Realistically, we can just hash this struct and use it as the "id".
    package var id: String {
        _id
    }

    private let _id = UUID().uuidString

    /// The path to the socket you'd like relayed. For .into
    /// direction this should be the path on the host to a unix socket.
    /// For direction .outOf this should be the path in the container/guest
    /// to a unix socket.
    public var source: URL

    /// The path you'd like the socket to be relayed to. For .into
    /// direction this should be the path in the container/guest. For
    /// direction .outOf this should be the path on your host.
    public var destination: URL

    /// What to set the file permissions of the unix socket being created
    /// to. For .into direction this will be the socket in the guest. For
    /// .outOf direction this will be the socket on the host.
    public var permissions: FilePermissions?

    /// The direction of the relay. `.into` for sharing a unix socket on your
    /// host into the container/guest. `outOf` shares a socket in the container/guest
    /// onto your host.
    public var direction: Direction

    /// Type that denotes the direction of the unix socket relay.
    public enum Direction: Sendable {
        /// Share the socket into the container/guest.
        case into
        /// Share a socket in the container/guest onto the host.
        case outOf
    }

    public init(
        source: URL,
        destination: URL,
        permissions: FilePermissions? = nil,
        direction: Direction = .into
    ) {
        self.source = source
        self.destination = destination
        self.permissions = permissions
        self.direction = direction
    }
}
