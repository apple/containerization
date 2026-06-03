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

/// Defines an AI coding agent that can be run inside a sandbox container.
///
/// Agent definitions can be built-in or loaded from JSON files in the
/// `agents/` subdirectory of the sandboxy config directory.
///
/// Location: `~/.config/sandboxy/agents/<name>.json`
///
/// Example (`foo.json`):
/// ```json
/// {
///     "displayName": "Foo",
///     "baseImage": "docker.io/library/python:3.12-slim",
///     "installCommands": [
///         "pip install foo"
///     ],
///     "launchCommand": ["foo"],
///     "environmentVariables": [],
///     "mounts": [
///         {"hostPath": "~/.foo", "containerPath": "/root/.foo", "readOnly": true}
///     ],
///     "allowedHosts": ["api.example.com", "*.cdn.example.com"]
/// }
/// ```
struct AgentDefinition: Codable, Sendable {
    /// Human-readable name used in output messages.
    let displayName: String

    /// The base container image reference (e.g., "docker.io/library/node:22").
    let baseImage: String

    /// Shell commands run sequentially inside the container to install the agent
    /// and its dependencies. Each string is passed as an argument to `sh -c`.
    let installCommands: [String]

    /// The command and arguments to launch the agent interactively.
    let launchCommand: [String]

    /// Environment variables required by the agent (key=value format).
    let environmentVariables: [String]

    /// Host paths to mount into the container. Each entry specifies a host path
    /// and a container path. Paths starting with `~` are expanded to the user's
    /// home directory. Only mounted if the host path exists.
    let mounts: [AgentMount]

    /// Default hostnames to allow through the network filtering proxy.
    /// Supports exact matches and `*.suffix` wildcard patterns.
    /// Merged with CLI `--allow-hosts` values.
    /// An empty list means all traffic is denied. Use `--no-network-filter` to disable filtering.
    let allowedHosts: [String]
}

/// A host-to-container mount for an agent definition.
struct AgentMount: Codable, Sendable {
    /// Path on the host. Supports `~` for the user's home directory.
    let hostPath: String

    /// Path inside the container where the host path is mounted.
    let containerPath: String

    /// Whether the mount is read-only. Defaults to `false`.
    let readOnly: Bool

    init(hostPath: String, containerPath: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostPath = try container.decode(String.self, forKey: .hostPath)
        containerPath = try container.decode(String.self, forKey: .containerPath)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    /// Returns the resolved absolute host path, expanding `~`.
    var resolvedHostPath: String {
        if hostPath.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
            return home + String(hostPath.dropFirst(1))
        }
        if hostPath == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        }
        return hostPath
    }
}

extension AgentDefinition {
    /// Built-in agent definitions, keyed by their CLI name.
    static let builtIn: [String: AgentDefinition] = [
        "claude": .claude
    ]

    /// Returns all available agents: built-in definitions merged with any
    /// user-defined agents from `<configRoot>/agents/`. If a user file matches
    /// a built-in agent name, non-nil fields from the user file override the
    /// built-in values, allowing partial overrides.
    static func allAgents(configRoot: URL) -> [String: AgentDefinition] {
        var agents = builtIn

        let agentsDir = configRoot.appendingPathComponent("agents")
        let agentsDirPath = agentsDir.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: agentsDirPath) else {
            return agents
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: agentsDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            let decoder = JSONDecoder()
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                do {
                    let data = try Data(contentsOf: file)
                    let override = try decoder.decode(AgentOverride.self, from: data)
                    if let base = agents[name] {
                        agents[name] = override.merged(onto: base)
                    } else {
                        agents[name] = try override.asFullDefinition()
                    }
                } catch {
                    ProgressUI.printWarning(
                        "Failed to load agent definition from \(file.lastPathComponent): \(error)")
                }
            }
        } catch {
            ProgressUI.printWarning("Failed to read agents directory: \(error)")
        }

        return agents
    }

    /// Returns the sorted list of available agent names for display in help text.
    static func knownAgentNames(configRoot: URL) -> [String] {
        allAgents(configRoot: configRoot).keys.sorted()
    }

    static let claude = AgentDefinition(
        displayName: "Claude Code",
        baseImage: "docker.io/library/node:22",
        installCommands: [
            "apt-get update && apt-get install -y --no-install-recommends less git procps sudo fzf zsh man-db unzip gnupg2 gh ipset iproute2 dnsutils aggregate jq nano vim ripgrep ca-certificates && apt-get clean && rm -rf /var/lib/apt/lists/*",
            "npm install -g @anthropic-ai/claude-code",
            "npm install -g global-agent",
        ],
        launchCommand: ["claude", "--dangerously-skip-permissions"],
        environmentVariables: [
            "ANTHROPIC_API_KEY",
            "NODE_OPTIONS=--max-old-space-size=4096",
            "IS_SANDBOX=1",
        ],
        mounts: [
            AgentMount(hostPath: "~/.claude", containerPath: "/root/.claude")
        ],
        allowedHosts: [
            "*.anthropic.com",
            "*.claude.com",
            "npm.org",
            "*.npmjs.org",
            "*.github.com",
            "*.githubusercontent.com",
            "*.pypi.org",
            "*.pythonhosted.org",
        ]
    )
}

/// All-optional mirror of `AgentDefinition` used when loading user override files.
/// For agents that match a built-in name, only the non-nil fields override the defaults.
/// For entirely new agents, all required fields must be provided.
struct AgentOverride: Codable, Sendable {
    var displayName: String?
    var baseImage: String?
    var installCommands: [String]?
    var launchCommand: [String]?
    var environmentVariables: [String]?
    var mounts: [AgentMount]?
    var allowedHosts: [String]?

    /// Merges this override onto a base definition, replacing only the fields
    /// that are non-nil in the override.
    func merged(onto base: AgentDefinition) -> AgentDefinition {
        AgentDefinition(
            displayName: displayName ?? base.displayName,
            baseImage: baseImage ?? base.baseImage,
            installCommands: installCommands ?? base.installCommands,
            launchCommand: launchCommand ?? base.launchCommand,
            environmentVariables: environmentVariables ?? base.environmentVariables,
            mounts: mounts ?? base.mounts,
            allowedHosts: allowedHosts ?? base.allowedHosts
        )
    }

    /// Converts this override into a full definition, throwing if any required
    /// fields are missing. Used for entirely new (non-built-in) agents.
    func asFullDefinition() throws -> AgentDefinition {
        guard let displayName, let baseImage, let installCommands,
            let launchCommand
        else {
            throw SandboxyError.incompleteAgentDefinition(
                missing: [
                    displayName == nil ? "displayName" : nil,
                    baseImage == nil ? "baseImage" : nil,
                    installCommands == nil ? "installCommands" : nil,
                    launchCommand == nil ? "launchCommand" : nil,
                ].compactMap { $0 }
            )
        }

        return AgentDefinition(
            displayName: displayName,
            baseImage: baseImage,
            installCommands: installCommands,
            launchCommand: launchCommand,
            environmentVariables: environmentVariables ?? [],
            mounts: mounts ?? [],
            allowedHosts: allowedHosts ?? []
        )
    }
}
