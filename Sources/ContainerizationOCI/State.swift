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

public enum ContainerState: String, Codable, Sendable {
    case creating
    case created
    case running
    case stopped
}

public struct State: Codable, Sendable {
    public init(
        version: String,
        id: String,
        status: ContainerState,
        pid: Int,
        bundle: String,
        annotations: [String: String]?
    ) {
        self.ociVersion = version
        self.id = id
        self.status = status
        self.pid = pid
        self.bundle = bundle
        self.annotations = annotations
    }

    public init(instance: State) {
        self.ociVersion = instance.ociVersion
        self.id = instance.id
        self.status = instance.status
        self.pid = instance.pid
        self.bundle = instance.bundle
        self.annotations = instance.annotations
    }

    public let ociVersion: String
    public let id: String
    public let status: ContainerState
    public let pid: Int
    public let bundle: String
    public var annotations: [String: String]?
}

public let seccompFdName: String = "seccompFd"

public struct ContainerProcessState: Codable, Sendable {
    public init(version: String, fds: [String], pid: Int, metadata: String, state: State) {
        self.ociVersion = version
        self.fds = fds
        self.pid = pid
        self.metadata = metadata
        self.state = state
    }

    public init(instance: ContainerProcessState) {
        self.ociVersion = instance.ociVersion
        self.fds = instance.fds
        self.pid = instance.pid
        self.metadata = instance.metadata
        self.state = instance.state
    }

    public let ociVersion: String
    public var fds: [String]
    public let pid: Int
    public let metadata: String
    public let state: State
}
