//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Get stats for a container"
    )

    @Argument(help: "Container ID")
    var container: String

    func run() async throws {
        let store = try ContainerStore()
        guard let container = await store.open(container) else {
            throw ContainerizationError(.notFound, message: "could not find container \(container)")
        }

        do {
            let stats = try await container.stats()

            print("CPU usage: \(String(format: "%.2f", Double(stats.cpuStats.totalUsage) / 1_000_000_000.0))s")
            print("Memory usage: \(stats.memoryStats.usageBytes / 1024 / 1024)MB / \(stats.memoryStats.limitBytes / 1024 / 1024)MB")
            print("PIDs: \(stats.pidsStats.current)")

        } catch {
            throw ContainerizationError(.internalError, message: "failed to get stats for container \(container): \(error)")
        }
    }
}
