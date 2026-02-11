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

/// The core error type for Containerization.
///
/// Most API surfaces for the core container/process/agent types will
/// return a ContainerizationError.
public struct ContainerizationError: Swift.Error, Sendable {
    /// A code describing the error encountered.
    public var code: Code
    /// A description of the error.
    public var message: String
    /// The original error which led to this error being thrown.
    public var cause: (any Error)?

    /// Creates a new error.
    ///
    /// - Parameters:
    ///   - code: The error code.
    ///   - message: A description of the error.
    ///   - cause: The original error which led to this error being thrown.
    public init(_ code: Code, message: String, cause: (any Error)? = nil) {
        self.code = code
        self.message = message
        self.cause = cause
    }

    /// Creates a new error.
    ///
    /// - Parameters:
    ///   - rawCode: The error code value as a String.
    ///   - message: A description of the error.
    ///   - cause: The original error which led to this error being thrown.
    public init(_ rawCode: String, message: String, cause: (any Error)? = nil) {
        self.code = Code(rawValue: rawCode)
        self.message = message
        self.cause = cause
    }

    /// Provides a unique hash of the error.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.code)
        hasher.combine(self.message)
    }

    /// Equality operator for the error. Uses the code and message.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code && lhs.message == rhs.message
    }

    /// Checks if the given error has the provided code.
    public func isCode(_ code: Code) -> Bool {
        self.code == code
    }
}

extension ContainerizationError: CustomStringConvertible {
    /// Description of the error.
    public var description: String {
        guard let cause = self.cause else {
            return "\(self.code): \"\(self.message)\""
        }
        return "\(self.code): \"\(self.message)\" (cause: \"\(cause)\")"
    }
}

extension ContainerizationError {
    /// Codes for a `ContainerizationError`.
    public struct Code: Sendable, Hashable {
        private enum Value: Hashable, Sendable, CaseIterable {
            case unknown
            case invalidArgument
            case internalError
            case exists
            case notFound
            case cancelled
            case invalidState
            case empty
            case timeout
            case unsupported
            case interrupted
        }

        private var value: Value
        private init(_ value: Value) {
            self.value = value
        }

        init(rawValue: String) {
            let values = Value.allCases.reduce(into: [String: Value]()) {
                $0[String(describing: $1)] = $1
            }

            let match = values[rawValue]
            guard let match else {
                fatalError("invalid code value \(rawValue)")
            }
            self.value = match
        }

        public static var unknown: Self {
            Self(.unknown)
        }

        public static var invalidArgument: Self {
            Self(.invalidArgument)
        }

        public static var internalError: Self {
            Self(.internalError)
        }

        public static var exists: Self {
            Self(.exists)
        }

        public static var notFound: Self {
            Self(.notFound)
        }

        public static var cancelled: Self {
            Self(.cancelled)
        }

        public static var invalidState: Self {
            Self(.invalidState)
        }

        public static var empty: Self {
            Self(.empty)
        }

        public static var timeout: Self {
            Self(.timeout)
        }

        public static var unsupported: Self {
            Self(.unsupported)
        }

        public static var interrupted: Self {
            Self(.interrupted)
        }
    }
}

extension ContainerizationError.Code: CustomStringConvertible {
    public var description: String {
        String(describing: self.value)
    }
}
