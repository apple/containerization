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
import ContainerizationError
import ContainerizationExtras
import Testing

@testable import Containerization

@Suite("BridgeManager")
struct BridgeManagerTests {
    @Test(arguments: [
        ("", "name must be non-empty"),
        ("reallyreallylongbridgename", "exceeds IFNAMSIZ-1 (15)"),
        ("bad/name", "contains invalid characters"),
        ("bad name", "contains invalid characters"),
        ("bad:name", "contains invalid characters"),
        ("bad\u{0000}name", "contains invalid characters"),
    ])
    func makeRejectsInvalidBridgeName(name: String, expectedMessage: String) throws {
        let subnet = try CIDRv4("192.168.64.0/24")

        do {
            _ = try BridgeManager.make(name: name, subnet: subnet)
            #expect(Bool(false), "expected invalidArgument for bridge name '\(name)'")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
            #expect(error.message.contains(expectedMessage))
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
    }

    @Test(arguments: [
        "",
        "reallyreallylongbridgename",
        "bad/name",
        "bad name",
    ])
    func initDoesNotTrapOnInvalidBridgeName(name: String) throws {
        let subnet = try CIDRv4("192.168.64.0/24")
        let manager = BridgeManager(name: name, subnet: subnet)

        #expect(manager.name == name)
        #expect(manager.subnet == subnet)
    }

    @Test(arguments: [
        ("", "egressInterface must be non-empty"),
        ("reallyreallylongegress", "exceeds IFNAMSIZ-1 (15)"),
        ("bad/name", "contains invalid characters"),
        ("bad name", "contains invalid characters"),
        ("bad:name", "contains invalid characters"),
        ("bad\u{0000}name", "contains invalid characters"),
    ])
    func makeRejectsInvalidEgressInterface(name: String, expectedMessage: String) throws {
        let subnet = try CIDRv4("192.168.64.0/24")

        do {
            _ = try BridgeManager.make(name: "cz0", subnet: subnet, egressInterface: name)
            #expect(Bool(false), "expected invalidArgument for egress interface '\(name)'")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
            #expect(error.message.contains(expectedMessage))
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
    }
}
#endif
