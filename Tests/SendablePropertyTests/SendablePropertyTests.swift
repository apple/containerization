//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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
import SendableProperty
import XCTest

final class SendablePropertyTests: XCTestCase {
    func testMacroWithTypeAnnotation() throws {
        final class TestMacro: Sendable {
            @SendableProperty
            var value: Int
        }

        let testMacro = TestMacro()
        testMacro.value = 42
        XCTAssertTrue(testMacro.value == 42)
    }

    func testMacroWithInitialValue() throws {
        final class TestMacro: Sendable {
            @SendableProperty
            var value = 0
        }

        let testMacro = TestMacro()
        XCTAssertTrue(type(of: testMacro.value) == Int.self)
        XCTAssertTrue(testMacro.value == 0)
        testMacro.value = 42
        XCTAssertTrue(testMacro.value == 42)
    }

    func testMacroWithTypeAnnotationAndInitialValue() throws {
        final class TestMacro: Sendable {
            @SendableProperty
            var value: Int = 0
        }

        let testMacro = TestMacro()
        testMacro.value = 42
        XCTAssertTrue(testMacro.value == 42)
    }

    func testMacroInConcurrentThreads() throws {
        final class TestMacro: Sendable {
            @SendableProperty
            var value = ""
        }

        let testMacro = TestMacro()
        let loremIpsum =
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."

        let numberOfIterations = 100_000
        let queue = DispatchQueue(label: "com.apple.sendable-property-tests", attributes: .concurrent)
        let dispatchGroup = DispatchGroup()
        for i in 0..<numberOfIterations {
            dispatchGroup.enter()
            queue.async {
                testMacro.value = "\(loremIpsum) (\(i))"
                dispatchGroup.leave()
            }
        }
        dispatchGroup.wait()
    }

    func testMacroWithSupportedTypes() throws {
        final class TestMacro: Sendable {
            @SendableProperty
            var int: Int
            @SendableProperty
            var uint: UInt
            @SendableProperty
            var int16: Int16
            @SendableProperty
            var uint16: UInt16
            @SendableProperty
            var int32: Int32
            @SendableProperty
            var uint32: UInt32
            @SendableProperty
            var int64: Int64
            @SendableProperty
            var uint64: UInt64
            @SendableProperty
            var float: Float
            @SendableProperty
            var double: Double
            @SendableProperty
            var bool: Bool
            @SendableProperty
            var unsafeRawPoiner: UnsafeRawPointer
            @SendableProperty
            var unsafeMutableRawPointer: UnsafeMutableRawPointer
            @SendableProperty
            var unsafePoiner: UnsafePointer<Int>
            @SendableProperty
            var unsafeMutablePointer: UnsafeMutablePointer<Int>

            @SendableProperty
            var intOpt: Int?
            @SendableProperty
            var uintOpt: UInt?
            @SendableProperty
            var int16Opt: Int16?
            @SendableProperty
            var uint16Opt: UInt16?
            @SendableProperty
            var int32Opt: Int32?
            @SendableProperty
            var uint32Opt: UInt32?
            @SendableProperty
            var int64Opt: Int64?
            @SendableProperty
            var uint64Opt: UInt64?
            @SendableProperty
            var floaOptt: Float?
            @SendableProperty
            var doubleOpt: Double?
            @SendableProperty
            var boolOpt: Bool?
            @SendableProperty
            var unsafeRawPoinerOpt: UnsafeRawPointer?
            @SendableProperty
            var unsafeMutableRawPointerOpt: UnsafeMutableRawPointer?
            @SendableProperty
            var unsafePoinerOpt: UnsafePointer<Int>?
            @SendableProperty
            var unsafeMutablePointerOpt: UnsafeMutablePointer<Int>?
        }
    }
}
