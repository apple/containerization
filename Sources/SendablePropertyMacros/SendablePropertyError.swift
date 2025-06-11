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

/// Errors that can be thrown by `@SendableProperty`.
enum SendablePropertyError: CustomStringConvertible, Error {
    case unexpectedError
    case onlyApplicableToVar

    var description: String {
        switch self {
        case .unexpectedError: return "@SendableProperty encountered an unexpected error"
        case .onlyApplicableToVar: return "@SendableProperty can only be applied to a variable"
        }
    }
}
