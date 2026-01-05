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

import ContainerizationOCI

/// `SystemPlatform` describes an operating system and architecture pair.
/// This is primarily used to choose what kind of OCI image to pull from a
/// registry.
public struct SystemPlatform: Sendable, Codable {
    public enum OS: String, CaseIterable, Sendable, Codable {
        case linux
        case darwin
    }
    public let os: OS

    public enum Architecture: String, CaseIterable, Sendable, Codable {
        case arm64
        case amd64
    }
    public let architecture: Architecture

    public func ociPlatform() -> ContainerizationOCI.Platform {
        ContainerizationOCI.Platform(arch: architecture.rawValue, os: os.rawValue)
    }

    public static var linuxArm: SystemPlatform { .init(os: .linux, architecture: .arm64) }
    public static var linuxAmd: SystemPlatform { .init(os: .linux, architecture: .amd64) }
}
