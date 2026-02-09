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

import ContainerizationExtras

/// Errors thrown when interacting with an ICMP socket.
public enum ICMPSocketError: Error, CustomStringConvertible, Equatable {
    case openFailed(errno: Int32)
    case closeFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)
    case invalidAddress(address: String)
    case permissionDenied
    case notImplemented

    public var description: String {
        switch self {
        case .openFailed(let errno):
            return "could not create ICMP socket, errno = \(errno)"
        case .closeFailed(let errno):
            return "could not create ICMP socket, errno = \(errno)"
        case .bindFailed(let errno):
            return "could not bind ICMP socket, errno = \(errno)"
        case .sendFailed(let errno):
            return "could not send ICMP packet, errno = \(errno)"
        case .receiveFailed(let errno):
            return "could not receive ICMP packet, errno = \(errno)"
        case .invalidAddress(let address):
            return "invalid address \(address)"
        case .permissionDenied:
            return "permission denied - raw sockets require root/CAP_NET_RAW"
        case .notImplemented:
            return "socket function not implemented for platform"
        }
    }
}
