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

//  Source: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/config.go

import ContainerizationError
import Foundation

/// Platform describes the platform which the image in the manifest runs on.
public struct Platform: Sendable, Equatable {
    public static var current: Self {
        var systemInfo = utsname()
        uname(&systemInfo)
        let arch = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        switch arch {
        case "arm64":
            return .init(arch: "arm64", os: "linux", variant: "v8")
        case "x86_64":
            return .init(arch: "amd64", os: "linux")
        default:
            fatalError("unsupported arch \(arch)")
        }
    }

    /// The computed description, for example, `linux/arm64/v8`.
    public var description: String {
        let architecture = architecture
        if let variant = variant {
            return "\(os)/\(architecture)/\(variant)"
        }
        return "\(os)/\(architecture)"
    }

    /// The CPU architecture, for example, `amd64` or `ppc64`.
    public var architecture: String {
        switch _rawArch {
        case "arm64", "aarch64":
            return "arm64"
        case "x86_64", "x86-64", "amd64":
            return "amd64"
        case "386", "ppc64le", "i386", "s390x", "riscv64":
            return _rawArch
        default:
            return _rawArch
        }
    }

    /// The operating system, for example, `linux` or `windows`.
    public var os: String {
        _rawOS
    }

    /// An optional field specifying the operating system version, for example on Windows `10.0.14393.1066`.
    public var osVersion: String?

    /// An optional field specifying an array of strings, each listing a required OS feature (for example on Windows `win32k`).
    public var osFeatures: [String]?

    /// An optional field specifying a variant of the CPU, for example `v7` to specify ARMv7 when architecture is `arm`.
    public var variant: String?

    /// The operation system of the image (eg. `linux`).
    private let _rawOS: String
    /// The CPU architecture (eg. `arm64`).
    private let _rawArch: String

    public init(arch: String, os: String, osVersion: String? = nil, osFeatures: [String]? = nil, variant: String? = nil) {
        self._rawArch = arch
        self._rawOS = os
        self.osVersion = osVersion
        self.osFeatures = osFeatures
        self.variant = variant
    }

    ///     Initializes a new platform from a string.
    ///     - Parameters:
    ///        -  platform: A `string` value representing the platform.
    ///     ```swift
    ///     // Create a new `ImagePlatform` from string.
    ///     let platform = try Platform(from: "linux/amd64")
    ///     ```
    ///     ## Throws ##
    ///     - Throws:  `Error.missingOS` if input is empty
    ///     - Throws:  `Error.invalidOS` if os is not `linux`
    ///     - Throws:  `Error.missingArch` if only one `/` is present
    ///     - Throws:  `Error.invalidArch` if an unrecognized architecture is provided
    ///     - Throws:  `Error.invalidVariant` if a variant is provided, and it does not apply to the specified architecture
    public init(from platform: String) throws {
        let items = platform.split(separator: "/", maxSplits: 1)
        guard let osValue = items.first else {
            throw ContainerizationError(.invalidArgument, message: "missing OS in \(platform)")
        }
        switch osValue {
        case "linux":
            _rawOS = osValue.description
        case "darwin":
            _rawOS = osValue.description
        case "windows":
            _rawOS = osValue.description
        default:
            throw ContainerizationError(.invalidArgument, message: "unknown OS in \(osValue)")
        }
        guard items.count > 1 else {
            throw ContainerizationError(.invalidArgument, message: "missing architecture in \(platform)")
        }

        guard let archItems = items.last?.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false) else {
            throw ContainerizationError(.invalidArgument, message: "missing architecture in \(platform)")
        }

        guard let archName = archItems.first else {
            throw ContainerizationError(.invalidArgument, message: "missing architecture in \(platform)")
        }

        switch archName {
        case "arm", "armhf", "armel":
            _rawArch = "arm"
            variant = "v7"
        case "aarch64", "arm64":
            variant = "v8"
            _rawArch = "arm64"
        case "x86_64", "x86-64", "amd64":
            _rawArch = "amd64"
        default:
            _rawArch = archName.description
        }

        if archItems.count == 2 {
            guard let archVariant = archItems.last else {
                throw ContainerizationError(.invalidArgument, message: "missing variant in \(platform)")
            }

            switch archName {
            case "arm":
                switch archVariant {
                case "v5", "v6", "v7", "v8":
                    variant = archVariant.description
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
                }
            case "armhf":
                switch archVariant {
                case "v7":
                    variant = "v7"
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
                }
            case "armel":
                switch archVariant {
                case "v6":
                    variant = "v6"
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
                }
            case "aarch64", "arm64":
                switch archVariant {
                case "v8", "8":
                    variant = "v8"
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
                }
            case "x86_64", "x86-64", "amd64":
                switch archVariant {
                case "v1":
                    variant = nil
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
                }
            case "i386", "386", "ppc64le", "riscv64":
                throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid variant \(archVariant)")
            }
        }
    }

}

extension Platform: Hashable {
    /**
      `~=` compares two platforms to check if **lhs** platform images are compatible with **rhs** platform
      This operator can be used to check if an image of **lhs** platform can run on **rhs**:
      - `true`:  when **rhs**=`arm/v8`, **lhs** is any of `arm/v8`, `arm/v7`, `arm/v6` and `arm/v5`
      - `true`:  when **rhs**=`arm/v7`, **lhs** is any of `arm/v7`, `arm/v6` and `arm/v5`
      - `true`:  when **rhs**=`arm/v6`, **lhs** is any of `arm/v6` and `arm/v5`
      - `true`:  when **rhs**=`amd64`, **lhs** is any of `amd64` and `386`
      - `true`:  when **rhs**=**lhs**
      - `false`:  otherwise
      - Parameters:
         - lhs: platform whose compatibility is being checked
         - rhs: platform against which compatibility is being checked
      - Returns: `true | false`
     */
    public static func ~= (lhs: Platform, rhs: Platform) -> Bool {
        if lhs.os == rhs.os {
            if lhs._rawArch == rhs._rawArch {
                switch rhs._rawArch {
                case "arm":
                    guard let lVariant = lhs.variant else {
                        return lhs == rhs
                    }
                    guard let rVariant = rhs.variant else {
                        return lhs == rhs
                    }
                    switch rVariant {
                    case "v8":
                        switch lVariant {
                        case "v5", "v6", "v7", "v8":
                            return true
                        default:
                            return false
                        }
                    case "v7":
                        switch lVariant {
                        case "v5", "v6", "v7":
                            return true
                        default:
                            return false
                        }
                    case "v6":
                        switch lVariant {
                        case "v5", "v6":
                            return true
                        default:
                            return false
                        }
                    default:
                        return lhs == rhs
                    }
                default:
                    return lhs == rhs
                }
            }
            if lhs._rawArch == "386" && rhs._rawArch == "amd64" {
                return true
            }
        }
        return false
    }

    /// `==` compares if **lhs** and **rhs** are the exact same platforms.
    public static func == (lhs: Platform, rhs: Platform) -> Bool {
        //  NOTE:
        //  If the platform struct was created by setting the fields directly and not using (from: String)
        //  then, there is a possibility that for arm64 architecture, the variant may be set to nil
        //  In that case, the variant should be assumed to v8
        if lhs.architecture == "arm64" && rhs.architecture == "arm64" {
            // The following checks effectively verify
            // that one operand has nil value and other has "v8"
            if lhs.variant == nil || rhs.variant == nil {
                if lhs.variant == "v8" || rhs.variant == "v8" {
                    return true
                }
            }
        }

        let osEqual = lhs.os == rhs.os
        let archEqual = lhs.architecture == rhs.architecture
        let variantEqual = lhs.variant == rhs.variant

        return osEqual && archEqual && variantEqual
    }

    public func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(description)
    }
}

extension Platform: Codable {

    enum CodingKeys: String, CodingKey {
        case os = "os"
        case architecture = "architecture"
        case variant = "variant"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(os, forKey: .os)
        try container.encode(architecture, forKey: .architecture)
        try container.encodeIfPresent(variant, forKey: .variant)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let architecture = try container.decodeIfPresent(String.self, forKey: .architecture)
        guard let architecture else {
            throw ContainerizationError(.invalidArgument, message: "missing architecture")
        }
        let os = try container.decodeIfPresent(String.self, forKey: .os)
        guard let os else {
            throw ContainerizationError(.invalidArgument, message: "missing OS")
        }
        let variant = try container.decodeIfPresent(String.self, forKey: .variant)
        self.init(arch: architecture, os: os, variant: variant)
    }
}

public func createPlatformMatcher(for platform: Platform?) -> @Sendable (Platform) -> Bool {
    if let platform {
        return { other in
            platform == other
        }
    }
    return { _ in
        true
    }
}

public func filterPlatforms(matcher: (Platform) -> Bool, _ descriptors: [Descriptor]) throws -> [Descriptor] {
    var outDescriptors: [Descriptor] = []
    for desc in descriptors {
        guard let p = desc.platform else {
            // pass along descriptor if the platform is not defined
            outDescriptors.append(desc)
            continue
        }
        if matcher(p) {
            outDescriptors.append(desc)
        }
    }
    return outDescriptors
}
