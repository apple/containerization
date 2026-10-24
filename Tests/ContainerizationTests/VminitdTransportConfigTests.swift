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

import Testing

@testable import Containerization

@Suite struct VminitdTransportConfigTests {
    /// The guest agent connection wraps an already-connected socket, so grpc-swift derives no
    /// `:authority` for it. Servers built on gRPC-Go v1.84.0 and later reject requests without
    /// one, so the configuration sets it explicitly.
    @Test func transportConfigSetsAuthority() {
        let authority = Vminitd.transportConfig().http2.authority
        #expect(authority == Vminitd.grpcAuthority)
        #expect(authority?.isEmpty == false)
    }

    /// The idle timeout must stay disabled: the connection to the guest agent is long-lived.
    @Test func transportConfigDisablesIdleTimeout() {
        #expect(Vminitd.transportConfig().connection.maxIdleTime == nil)
    }
}
