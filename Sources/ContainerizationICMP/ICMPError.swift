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

/// Errors that may occur during ICMP operations
public enum ICMPError: Swift.Error, CustomStringConvertible {
    case invalidPacket(String)
    case invalidResponse(String)
    case timeout
    case unexpectedMessageType(expected: UInt8, got: UInt8)
    case bufferTooSmall(needed: Int, available: Int)
    case cancelled

    public var description: String {
        switch self {
        case .invalidPacket(let message):
            return "packet validation error: \(message)"
        case .invalidResponse(let message):
            return "invalid response: \(message)"
        case .timeout:
            return "request timed out"
        case .unexpectedMessageType(let expected, let got):
            return "unexpected message type: expected \(expected), got \(got)"
        case .bufferTooSmall(let needed, let available):
            return "buffer too small: needed \(needed), available \(available)"
        case .cancelled:
            return "operation was cancelled"
        }
    }
}
