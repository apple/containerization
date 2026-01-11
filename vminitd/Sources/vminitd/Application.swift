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

import ContainerizationOS
import Foundation
import Logging

@main
struct Application {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)

        // Parse command line arguments
        let args = CommandLine.arguments
        let command = args.count > 1 ? args[1] : "init"

        switch command {
        case "pause":
            let log = Logger(label: "pause")

            log.info("Running pause command")
            try PauseCommand.run(log: log)
        case "init":
            fallthrough
        default:
            let log = Logger(label: "vminitd")

            log.info("Running init command")
            try Self.mountProc(log: log)
            try await InitCommand.run(log: log)
        }
    }

    // Swift seems like it has some fun issues trying to spawn threads if /proc isn't around, so we
    // do this before calling our first async function.
    static func mountProc(log: Logger) throws {
        // Is it already mounted (would only be true in debug builds where we re-exec ourselves)?
        if isProcMounted() {
            return
        }

        log.info("mounting /proc")

        let mnt = ContainerizationOS.Mount(
            type: "proc",
            source: "proc",
            target: "/proc",
            options: []
        )
        try mnt.mount(createWithPerms: 0o755)
    }

    static func isProcMounted() -> Bool {
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
