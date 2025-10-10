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
import Testing

@testable import ContainerizationError

struct ContainerizationErrorTests {

    // MARK: - Initialization Tests

    @Test
    func testInitWithCodeAndMessage() {
        let error = ContainerizationError(.notFound, message: "Resource not found")

        #expect(error.code == .notFound)
        #expect(error.message == "Resource not found")
        #expect(error.cause == nil)
    }

    @Test
    func testInitWithCodeMessageAndCause() {
        struct UnderlyingError: Error {}
        let cause = UnderlyingError()
        let error = ContainerizationError(.internalError, message: "Internal failure", cause: cause)

        #expect(error.code == .internalError)
        #expect(error.message == "Internal failure")
        #expect(error.cause != nil)
    }

    @Test
    func testInitWithRawCodeAndMessage() {
        let error = ContainerizationError("timeout", message: "Operation timed out")

        #expect(error.code == .timeout)
        #expect(error.message == "Operation timed out")
        #expect(error.cause == nil)
    }

    @Test
    func testInitWithRawCodeMessageAndCause() {
        struct TestError: Error {}
        let cause = TestError()
        let error = ContainerizationError("cancelled", message: "Request cancelled", cause: cause)

        #expect(error.code == .cancelled)
        #expect(error.message == "Request cancelled")
        #expect(error.cause != nil)
    }

    // MARK: - Error Code Tests

    @Test
    func testAllErrorCodes() {
        let codes: [(ContainerizationError.Code, String)] = [
            (.unknown, "unknown"),
            (.invalidArgument, "invalidArgument"),
            (.internalError, "internalError"),
            (.exists, "exists"),
            (.notFound, "notFound"),
            (.cancelled, "cancelled"),
            (.invalidState, "invalidState"),
            (.empty, "empty"),
            (.timeout, "timeout"),
            (.unsupported, "unsupported"),
            (.interrupted, "interrupted"),
        ]

        for (code, expectedDescription) in codes {
            #expect(code.description == expectedDescription)

            // Test that raw value initialization works
            let codeFromRaw = ContainerizationError.Code(rawValue: expectedDescription)
            #expect(codeFromRaw == code)
        }
    }

    @Test
    func testIsCodeMethod() {
        let error = ContainerizationError(.notFound, message: "Test")

        #expect(error.isCode(.notFound))
        #expect(!error.isCode(.exists))
        #expect(!error.isCode(.timeout))
    }

    // MARK: - Equality and Hashing Tests

    @Test
    func testEquality() {
        let error1 = ContainerizationError(.notFound, message: "Resource not found")
        let error2 = ContainerizationError(.notFound, message: "Resource not found")
        let error3 = ContainerizationError(.exists, message: "Resource not found")
        let error4 = ContainerizationError(.notFound, message: "Different message")

        // Same code and message should be equal
        #expect(error1 == error2)

        // Different code should not be equal
        #expect(!(error1 == error3))

        // Different message should not be equal
        #expect(!(error1 == error4))
    }

    @Test
    func testEqualityWithCause() {
        struct TestError: Error {}
        let cause1 = TestError()
        let cause2 = TestError()

        let error1 = ContainerizationError(.internalError, message: "Test", cause: cause1)
        let error2 = ContainerizationError(.internalError, message: "Test", cause: cause2)
        let error3 = ContainerizationError(.internalError, message: "Test")

        // Errors with same code and message should be equal regardless of cause
        #expect(error1 == error2)
        #expect(error1 == error3)
    }

    @Test
    func testHashing() {
        let error1 = ContainerizationError(.timeout, message: "Operation timed out")
        let error2 = ContainerizationError(.timeout, message: "Operation timed out")
        let error3 = ContainerizationError(.cancelled, message: "Operation timed out")

        // Test that hashing works by creating hasher manually
        var hasher1 = Hasher()
        error1.hash(into: &hasher1)
        let hash1 = hasher1.finalize()

        var hasher2 = Hasher()
        error2.hash(into: &hasher2)
        let hash2 = hasher2.finalize()

        var hasher3 = Hasher()
        error3.hash(into: &hasher3)
        let hash3 = hasher3.finalize()

        #expect(hash1 == hash2)
        #expect(hash1 != hash3)
    }

    // MARK: - Description Tests

    @Test
    func testDescriptionWithoutCause() {
        let error = ContainerizationError(.notFound, message: "Resource not available")
        let expected = "notFound: \"Resource not available\""

        #expect(error.description == expected)
    }

    @Test
    func testDescriptionWithCause() {
        struct UnderlyingError: Error, CustomStringConvertible {
            var description: String { "Underlying error occurred" }
        }

        let cause = UnderlyingError()
        let error = ContainerizationError(.internalError, message: "Processing failed", cause: cause)
        let expected = "internalError: \"Processing failed\" (cause: \"Underlying error occurred\")"

        #expect(error.description == expected)
    }

    @Test
    func testDescriptionWithGenericCause() {
        struct GenericError: Error {}

        let cause = GenericError()
        let error = ContainerizationError(.interrupted, message: "Process interrupted", cause: cause)

        // Should contain the error and message, and indicate there's a cause
        #expect(error.description.contains("interrupted"))
        #expect(error.description.contains("Process interrupted"))
        #expect(error.description.contains("cause:"))
    }

    // MARK: - Code Validation Tests

    @Test
    func testCodeEquality() {
        let code1 = ContainerizationError.Code.unknown
        let code2 = ContainerizationError.Code.unknown
        let code3 = ContainerizationError.Code.notFound

        #expect(code1 == code2)
        #expect(code1 != code3)
    }

    @Test
    func testCodeHashable() {
        let code1 = ContainerizationError.Code.exists
        let code2 = ContainerizationError.Code.exists
        let code3 = ContainerizationError.Code.empty

        #expect(code1.hashValue == code2.hashValue)
        #expect(code1.hashValue != code3.hashValue)
    }

    // MARK: - Error Protocol Conformance Tests

    @Test
    func testErrorProtocolConformance() {
        let error = ContainerizationError(.unsupported, message: "Feature not supported")
        let swiftError: Error = error

        // Should be able to cast back to ContainerizationError
        let castError = swiftError as? ContainerizationError
        #expect(castError != nil)
        #expect(castError?.code == .unsupported)
        #expect(castError?.message == "Feature not supported")
    }

    @Test
    func testSendableConformance() {
        // This is a compile-time test - if ContainerizationError wasn't Sendable,
        // this wouldn't compile in strict concurrency mode
        let error = ContainerizationError(.timeout, message: "Timeout occurred")

        Task {
            let _ = error  // Should compile without warnings
        }
    }

    // MARK: - Edge Cases and Error Scenarios

    @Test
    func testEmptyMessage() {
        let error = ContainerizationError(.invalidArgument, message: "")

        #expect(error.message.isEmpty)
        #expect(error.description == "invalidArgument: \"\"")
    }

    @Test
    func testMessageWithSpecialCharacters() {
        let message = "Error with \"quotes\" and \n newlines and \t tabs"
        let error = ContainerizationError(.internalError, message: message)

        #expect(error.message == message)
        #expect(error.description.contains(message))
    }

    @Test
    func testLongMessage() {
        let longMessage = String(repeating: "This is a very long error message. ", count: 100)
        let error = ContainerizationError(.unknown, message: longMessage)

        #expect(error.message == longMessage)
        #expect(error.description.contains(longMessage))
    }
}
