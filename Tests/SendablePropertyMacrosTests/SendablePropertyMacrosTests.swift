//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

// Macro implementations build for the host, so the corresponding module is not available when cross-compiling. Cross-compiled tests may still make use of the macro itself in end-to-end tests.
#if canImport(SendablePropertyMacros)
import SendablePropertyMacros

// testMacros is thread-safe.
nonisolated(unsafe) let testMacros: [String: Macro.Type] = [
    "SendableProperty": SendablePropertyMacro.self
]
#endif

final class SendablePropertyMacrosTests: XCTestCase {
    func testMacroExpansionWithTypeAnnotation() throws {
        #if canImport(SendablePropertyMacros)
        assertMacroExpansion(
            """
            final class TestMacro: Sendable {
                @SendableProperty
                var value: Int
            }
            """,
            expandedSource:
                """
                final class TestMacro: Sendable {
                    var value: Int {
                        get {
                            _value.withLock {
                                $0!
                            }
                        }
                        set {
                            _value.withLock {
                                $0 = newValue
                            }
                        }
                    }

                    internal let _value = Synchronized<Int?>(nil)
                }
                """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testMacroExpansionWithInitialValue() throws {
        #if canImport(SendablePropertyMacros)
        assertMacroExpansion(
            """
            final class TestMacro: Sendable {
                @SendableProperty
                var value = 0
            }
            """,
            expandedSource:
                """
                final class TestMacro: Sendable {
                    var value {
                        get {
                            _value.withLock {
                                $0
                            }
                        }
                        set {
                            _value.withLock {
                                $0 = newValue
                            }
                        }
                    }

                    internal let _value = Synchronized(0)
                }
                """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testMacroExpansionWithTypeAnnotationAndInitialValue() throws {
        #if canImport(SendablePropertyMacros)
        assertMacroExpansion(
            """
            final class TestMacro: Sendable {
                @SendableProperty
                var value: Int = 0
            }
            """,
            expandedSource:
                """
                final class TestMacro: Sendable {
                    var value: Int {
                        get {
                            _value.withLock {
                                $0
                            }
                        }
                        set {
                            _value.withLock {
                                $0 = newValue
                            }
                        }
                    }

                    internal let _value = Synchronized<Int>(0)
                }
                """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }
}
