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
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List sandbox instances",
            aliases: ["ls"]
        )

        func run() async throws {
            _ = try Sandboxy.loadConfig()

            let instances = try InstanceState.loadAll(appRoot: Sandboxy.appRoot)

            if instances.isEmpty {
                print("No sandbox instances found.")
                return
            }

            // Deduplicate named instances, keeping only the most recent entry per name.
            var seen = Set<String>()
            var deduplicated: [InstanceState] = []
            let sorted = instances.sorted { $0.createdAt > $1.createdAt }
            for instance in sorted {
                if let name = instance.name {
                    if seen.contains(name) { continue }
                    seen.insert(name)
                }
                deduplicated.append(instance)
            }

            print(
                pad("NAME", to: 30)
                    + pad("AGENT", to: 12)
                    + pad("STATUS", to: 12)
                    + pad("CREATED", to: 12)
                    + "WORKSPACE"
            )

            for instance in deduplicated {
                let age = relativeTime(from: instance.createdAt)
                let displayName = instance.name ?? "-"
                print(
                    pad(truncate(displayName, to: 28), to: 30)
                        + pad(instance.agent, to: 12)
                        + pad(instance.status.rawValue, to: 12)
                        + pad(age, to: 12)
                        + instance.workspace
                )
            }
        }

        private func pad(_ s: String, to width: Int) -> String {
            if s.count >= width {
                return s
            }
            return s + String(repeating: " ", count: width - s.count)
        }

        private func truncate(_ s: String, to maxLen: Int) -> String {
            if s.count <= maxLen { return s }
            return "..." + String(s.suffix(maxLen - 3))
        }

        private func relativeTime(from date: Date) -> String {
            let seconds = Int(Date().timeIntervalSince(date))
            if seconds < 60 { return "\(seconds)s ago" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m ago" }
            let hours = minutes / 60
            if hours < 24 { return "\(hours)h ago" }
            let days = hours / 24
            return "\(days)d ago"
        }
    }
}
