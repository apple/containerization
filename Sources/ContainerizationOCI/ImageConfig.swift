//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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

//  Source: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/config.go

import Foundation

/// ImageConfig defines the execution parameters which should be used as a base when running a container using an image.
public struct ImageConfig: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case user = "User"
        case env = "Env"
        case entrypoint = "Entrypoint"
        case cmd = "Cmd"
        case workingDir = "WorkingDir"
        case labels = "Labels"
        case stopSignal = "StopSignal"
    }

    /// user defines the username or UID which the process in the container should run as.
    public let user: String?

    /// env is a list of environment variables to be used in a container.
    public let env: [String]?

    /// entrypoint defines a list of arguments to use as the command to execute when the container starts.
    public let entrypoint: [String]?

    /// cmd defines the default arguments to the entrypoint of the container.
    public let cmd: [String]?

    /// workingDir sets the current working directory of the entrypoint process in the container.
    public let workingDir: String?

    /// labels contains arbitrary metadata for the container.
    public let labels: [String: String]?

    /// stopSignal contains the system call signal that will be sent to the container to exit.
    public let stopSignal: String?

    public init(
        user: String? = nil, env: [String]? = nil, entrypoint: [String]? = nil, cmd: [String]? = nil,
        workingDir: String? = nil, labels: [String: String]? = nil, stopSignal: String? = nil
    ) {
        self.user = user
        self.env = env
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.workingDir = workingDir
        self.labels = labels
        self.stopSignal = stopSignal
    }
}

/// RootFS describes a layer content addresses
public struct Rootfs: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case type
        case diffIDs = "diff_ids"
    }

    /// type is the type of the rootfs.
    public let type: String

    /// diffIDs is an array of layer content hashes (DiffIDs), in order from bottom-most to top-most.
    public let diffIDs: [String]

    public init(type: String, diffIDs: [String]) {
        self.type = type
        self.diffIDs = diffIDs
    }
}

/// History describes the history of a layer.
public struct History: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case created
        case createdBy = "created_by"
        case author
        case comment
        case emptyLayer = "empty_layer"
    }

    /// created is the combined date and time at which the layer was created, formatted as defined by RFC 3339, section 5.6.
    public let created: String?

    /// createdBy is the command which created the layer.
    public let createdBy: String?

    /// author is the author of the build point.
    public let author: String?

    /// comment is a custom message set when creating the layer.
    public let comment: String?

    /// emptyLayer is used to mark if the history item created a filesystem diff.
    public let emptyLayer: Bool?

    public init(
        created: String? = nil, createdBy: String? = nil, author: String? = nil, comment: String? = nil,
        emptyLayer: Bool? = nil
    ) {
        self.created = created
        self.createdBy = createdBy
        self.author = author
        self.comment = comment
        self.emptyLayer = emptyLayer
    }
}

/// Image is the JSON structure which describes some basic information about the image.
/// This provides the `application/vnd.oci.image.config.v1+json` mediatype when marshalled to JSON.
public struct Image: Codable, Sendable {
    /// created is the combined date and time at which the image was created, formatted as defined by RFC 3339, section 5.6.
    public let created: String?

    /// author defines the name and/or email address of the person or entity which created and is responsible for maintaining the image.
    public let author: String?

    /// architecture field specifies the CPU architecture, for example `amd64` or `ppc64`.
    public let architecture: String

    /// os specifies the operating system, for example `linux` or `windows`.
    public let os: String

    /// osVersion is an optional field specifying the operating system version, for example on Windows `10.0.14393.1066`.
    public let osVersion: String?

    /// osFeatures is an optional field specifying an array of strings, each listing a required OS feature (for example on Windows `win32k`).
    public let osFeatures: [String]?

    /// variant is an optional field specifying a variant of the CPU, for example `v7` to specify ARMv7 when architecture is `arm`.
    public let variant: String?

    /// config defines the execution parameters which should be used as a base when running a container using the image.
    public let config: ImageConfig?

    /// rootfs references the layer content addresses used by the image.
    public let rootfs: Rootfs

    /// history describes the history of each layer.
    public let history: [History]?

    public init(
        created: String? = nil, author: String? = nil, architecture: String, os: String, osVersion: String? = nil,
        osFeatures: [String]? = nil, variant: String? = nil, config: ImageConfig? = nil, rootfs: Rootfs,
        history: [History]? = nil
    ) {
        self.created = created
        self.author = author
        self.architecture = architecture
        self.os = os
        self.osVersion = osVersion
        self.osFeatures = osFeatures
        self.variant = variant
        self.config = config
        self.rootfs = rootfs
        self.history = history
    }
}
