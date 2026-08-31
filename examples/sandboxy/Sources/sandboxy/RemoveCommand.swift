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
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove sandbox instances and their preserved state"
        )

        @Argument(help: "Name of the instance to remove")
        var names: [String] = []

        @Flag(name: [.customShort("a"), .long], help: "Remove all instances")
        var all: Bool = false

        func run() async throws {
            _ = try Sandboxy.loadConfig()

            if all {
                let instances = try InstanceState.loadAll(appRoot: Sandboxy.appRoot)
                if instances.isEmpty {
                    print("No instances to remove.")
                    return
                }
                for instance in instances {
                    let displayName = instance.name ?? instance.id
                    do {
                        try instance.removeAll(appRoot: Sandboxy.appRoot)
                        print("Removed instance '\(displayName)'.")
                    } catch {
                        print("Failed to remove instance '\(displayName)': \(error)")
                    }
                }
                return
            }

            guard !names.isEmpty else {
                print("Specify instance name(s) to remove, or use --all (-a).")
                throw ExitCode.failure
            }

            for name in names {
                guard let instance = try InstanceState.find(name: name, appRoot: Sandboxy.appRoot) else {
                    print("No instance named '\(name)' found.")
                    continue
                }
                try instance.removeAll(appRoot: Sandboxy.appRoot)
                print("Removed instance '\(name)'.")
            }
        }
    }
}
