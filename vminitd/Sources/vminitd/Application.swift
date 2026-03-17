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

import ArgumentParser
import ContainerizationOS
import Foundation
import Logging

@main
struct Application: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vminitd",
        abstract: "Virtual machine init daemon",
        version: "0.1.0",
        subcommands: [
            AgentCommand.self,
            InitCommand.self,
            PauseCommand.self,
        ],
        defaultSubcommand: AgentCommand.self
    )

    static func main() async throws {
        // Busybox-style: if invoked as .cz-init, run init mode directly.
        let invoked = CommandLine.arguments.first?.split(separator: "/").last.map(String.init) ?? ""
        if invoked == ".cz-init" {
            let args = Array(CommandLine.arguments.dropFirst())
            var command = try InitCommand.parse(args)
            try command.run()
            return
        }

        // Swift has issues spawning threads if /proc isn't mounted,
        // so we do this synchronously before any async code runs.
        try mountProc()

        var command = try parseAsRoot()
        if let asyncCommand = command as? AsyncParsableCommand {
            nonisolated(unsafe) var unsafeCommand = asyncCommand
            try await unsafeCommand.run()
        } else {
            try command.run()
        }
    }

    private static func mountProc() throws {
        // Is it already mounted (would only be true in debug builds where we re-exec ourselves)?
        if isProcMounted() {
            return
        }

        let mnt = ContainerizationOS.Mount(
            type: "proc",
            source: "proc",
            target: "/proc",
            options: []
        )
        try mnt.mount(createWithPerms: 0o755)
    }

    private static func isProcMounted() -> Bool {
        guard let data = try? String(contentsOfFile: "/proc/mounts", encoding: .utf8) else {
            return false
        }

        for line in data.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count >= 2 {
                let mountPoint = String(fields[1])
                if mountPoint == "/proc" {
                    return true
                }
            }
        }

        return false
    }
}

struct LogLevelOption: ParsableArguments {
    @Option(name: .long, help: "Set the log level (trace, debug, info, notice, warning, error, critical)")
    var logLevel: String = "info"

    func resolvedLogLevel() -> Logger.Level {
        switch logLevel.lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "info":
            return .info
        case "notice":
            return .notice
        case "warning":
            return .warning
        case "error":
            return .error
        case "critical":
            return .critical
        default:
            return .info
        }
    }
}

func makeLogger(label: String, level: Logger.Level) -> Logger {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    var log = Logger(label: label)
    log.logLevel = level
    return log
}
