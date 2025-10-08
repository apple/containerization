//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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

/// Statistics for a network interface.
public struct InterfaceStatistics {
    public var name: String
    public var receivedPackets: UInt64?
    public var transmittedPackets: UInt64?
    public var receivedBytes: UInt64?
    public var transmittedBytes: UInt64?
    public var receivedErrors: UInt64?
    public var transmittedErrors: UInt64?

    public init(
        name: String,
        receivedPackets: UInt64?,
        transmittedPackets: UInt64?,
        receivedBytes: UInt64?,
        transmittedBytes: UInt64?,
        receivedErrors: UInt64?,
        transmittedErrors: UInt64?
    ) {
        self.name = name
        self.receivedPackets = receivedPackets
        self.transmittedPackets = transmittedPackets
        self.receivedBytes = receivedBytes
        self.transmittedBytes = transmittedBytes
        self.receivedErrors = receivedErrors
        self.transmittedErrors = transmittedErrors
    }
}
