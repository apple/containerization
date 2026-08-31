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

import ArgumentParser
import Foundation

extension Sandboxy {
    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "View and create configuration files",
            subcommands: [
                ConfigList.self,
                ConfigCreate.self,
            ]
        )
    }

    struct ConfigList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Print current configuration and agent definitions"
        )

        @Option(name: .long, help: "Print the definition for a specific agent")
        var agent: String?

        @Flag(name: .long, help: "Print built-in defaults instead of the resolved configuration")
        var defaults = false

        @Flag(name: .long, help: "Print configuration file paths")
        var paths = false

        @Flag(name: .long, help: "List available agents")
        var agents = false

        func run() async throws {
            if paths {
                let configPath = Sandboxy.configRoot.appendingPathComponent("config.json")
                let agentsDir = Sandboxy.configRoot.appendingPathComponent("agents")
                print("Config:  \(configPath.path(percentEncoded: false))")
                print("Agents:  \(agentsDir.path(percentEncoded: false))")
                print("Data:    \(Sandboxy.appRoot.path(percentEncoded: false))")
                return
            }

            if agents {
                let allAgents = AgentDefinition.allAgents(configRoot: Sandboxy.configRoot)
                let builtInNames = Set(AgentDefinition.builtIn.keys)
                for name in allAgents.keys.sorted() {
                    let definition = allAgents[name]!
                    let source = builtInNames.contains(name) ? "built-in" : "custom"
                    print("  \(name) - \(definition.displayName) (\(source))")
                }
                return
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            if let agentName = agent {
                let allAgents = AgentDefinition.allAgents(configRoot: Sandboxy.configRoot)
                guard let definition = allAgents[agentName] else {
                    let available = allAgents.keys.sorted().joined(separator: ", ")
                    throw ValidationError(
                        "Unknown agent '\(agentName)'. Available agents: \(available)"
                    )
                }
                let data = try encoder.encode(definition)
                print(String(data: data, encoding: .utf8)!)
            } else {
                let config = defaults ? SandboxyConfig.defaults : try Sandboxy.loadConfig()
                let data = try encoder.encode(config)
                print(String(data: data, encoding: .utf8)!)
            }
        }
    }

    struct ConfigCreate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a default configuration or agent definition file"
        )

        @Option(name: .long, help: "Create a definition file for a new agent with this name")
        var agent: String?

        @Flag(name: .long, help: "Overwrite existing files without prompting")
        var force = false

        func run() async throws {
            let fm = FileManager.default
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            if let agentName = agent {
                let agentsDir = Sandboxy.configRoot.appendingPathComponent("agents")
                try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

                let filePath = agentsDir.appendingPathComponent("\(agentName).json")
                if fm.fileExists(atPath: filePath.path(percentEncoded: false)) && !force {
                    guard isatty(STDIN_FILENO) != 0 else {
                        print("Agent definition already exists at \(filePath.path(percentEncoded: false)). Use --force to overwrite.")
                        throw ExitCode.failure
                    }
                    print("Agent definition already exists at \(filePath.path(percentEncoded: false))")
                    print("Overwrite? [y/N] ", terminator: "")
                    guard let response = readLine()?.lowercased(), response == "y" || response == "yes" else {
                        print("Aborted.")
                        return
                    }
                }

                let definition: AgentDefinition
                if let builtIn = AgentDefinition.builtIn[agentName] {
                    definition = builtIn
                } else {
                    definition = AgentDefinition(
                        displayName: agentName.capitalized,
                        baseImage: "docker.io/library/node:22",
                        installCommands: [],
                        launchCommand: [agentName],
                        environmentVariables: [],
                        mounts: [],
                        allowedHosts: []
                    )
                }

                let data = try encoder.encode(definition)
                try data.write(to: filePath, options: .atomic)
                print("Created agent definition at \(filePath.path(percentEncoded: false))")
                print()
                print(String(data: data, encoding: .utf8)!)
            } else {
                let configPath = Sandboxy.configRoot.appendingPathComponent("config.json")
                if fm.fileExists(atPath: configPath.path(percentEncoded: false)) && !force {
                    guard isatty(STDIN_FILENO) != 0 else {
                        print("Configuration file already exists at \(configPath.path(percentEncoded: false)). Use --force to overwrite.")
                        throw ExitCode.failure
                    }
                    print("Configuration file already exists at \(configPath.path(percentEncoded: false))")
                    print("Overwrite? [y/N] ", terminator: "")
                    guard let response = readLine()?.lowercased(), response == "y" || response == "yes" else {
                        print("Aborted.")
                        return
                    }
                }

                try fm.createDirectory(at: Sandboxy.configRoot, withIntermediateDirectories: true)

                let data = try encoder.encode(SandboxyConfig.defaults)
                try data.write(to: configPath, options: .atomic)
                print("Created configuration file at \(configPath.path(percentEncoded: false))")
            }
        }
    }
}
