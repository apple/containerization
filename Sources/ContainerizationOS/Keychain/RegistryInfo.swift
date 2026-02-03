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

import Foundation

/// Holds the stored attributes for a registry.
public struct RegistryInfo: Sendable {
    /// The registry host as a domain name with an optional port.
    public var hostname: String
    /// The username used to authenticate with the registry.
    public var username: String
    /// The date the registry was last modified.
    public let modifiedDate: Date
    /// The date the registry was created.
    public let createdDate: Date
}
