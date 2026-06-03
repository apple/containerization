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

/// Optional configuration file for overriding sandboxy defaults.
///
/// If `config.json` exists in the sandboxy config directory, it is
/// loaded at startup and its values override the built-in defaults. Any field
/// can be omitted to keep the default.
///
/// Location: `~/.config/sandboxy/config.json`
///
/// Example:
/// ```json
/// {
///     "dataDir": "/Volumes/fast/sandboxy",
///     "kernel": "/path/to/vmlinux",
///     "initfsReference": "ghcr.io/apple/containerization/vminit:latest",
///     "defaultCPUs": 4,
///     "defaultMemory": "4g"
/// }
/// ```
struct SandboxyConfig: Codable, Sendable {
    /// Directory for runtime data (caches, content store, containers).
    /// Defaults to `~/Library/Application Support/com.apple.containerization.sandboxy`.
    var dataDir: String?
    /// Path to a Linux kernel binary on disk. When set, the auto-download is skipped.
    var kernel: String?
    /// OCI reference for the VM init image.
    var initfsReference: String?
    /// Default number of CPUs for new containers.
    var defaultCPUs: Int?
    /// Default memory for new containers (e.g. "4g", "512m", "4096" for MB).
    var defaultMemory: String?

    /// Built-in defaults used when no config file is present.
    static let defaults = SandboxyConfig(
        initfsReference: "ghcr.io/apple/containerization/vminit:0.30.0",
        defaultCPUs: 4,
        defaultMemory: "4g"
    )

    /// Loads the config from `<configRoot>/config.json`, falling back to defaults
    /// for any missing fields.
    static func load(configRoot: URL) throws -> SandboxyConfig {
        let configPath = configRoot.appendingPathComponent("config.json")

        guard FileManager.default.fileExists(atPath: configPath.path(percentEncoded: false)) else {
            return .defaults
        }

        do {
            let data = try Data(contentsOf: configPath)
            let userConfig = try JSONDecoder().decode(SandboxyConfig.self, from: data)

            return SandboxyConfig(
                dataDir: userConfig.dataDir,
                kernel: userConfig.kernel,
                initfsReference: userConfig.initfsReference ?? defaults.initfsReference,
                defaultCPUs: userConfig.defaultCPUs ?? defaults.defaultCPUs,
                defaultMemory: userConfig.defaultMemory ?? defaults.defaultMemory
            )
        } catch {
            throw SandboxyError.configFailedToLoad(error: error)
        }
    }
}
