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
    struct Cache: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cache",
            abstract: "Manage cached rootfs images",
            subcommands: [
                CacheList.self,
                CacheRemove.self,
                CacheClean.self,
            ]
        )
    }

    struct CacheList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List cached rootfs images and named instance state"
        )

        func run() async throws {
            _ = try Sandboxy.loadConfig()

            let cacheDir = Sandboxy.appRoot.appendingPathComponent("cache")
            let namedDir = InstanceState.namedRootfsDir(appRoot: Sandboxy.appRoot)

            let agentCaches = listRootfsFiles(in: cacheDir, suffix: "-rootfs.ext4")
            let namedCaches = listRootfsFiles(in: namedDir, suffix: "-rootfs.ext4")

            if agentCaches.isEmpty && namedCaches.isEmpty {
                print("No cached images found.")
                return
            }

            if !agentCaches.isEmpty {
                print("Agent caches:")
                print(pad("  NAME", to: 20) + pad("SIZE", to: 12) + "MODIFIED")
                for entry in agentCaches {
                    print(
                        pad("  \(entry.name)", to: 20)
                            + pad(formatBytes(entry.diskSize), to: 12)
                            + entry.modified
                    )
                }
            }

            if !namedCaches.isEmpty {
                if !agentCaches.isEmpty { print() }
                print("Named instances:")
                print(pad("  NAME", to: 20) + pad("SIZE", to: 12) + "MODIFIED")
                for entry in namedCaches {
                    print(
                        pad("  \(entry.name)", to: 20)
                            + pad(formatBytes(entry.diskSize), to: 12)
                            + entry.modified
                    )
                }
            }
        }

        private struct CacheEntry {
            let name: String
            let diskSize: UInt64
            let modified: String
        }

        private func listRootfsFiles(in dir: URL, suffix: String) -> [CacheEntry] {
            let dirPath = dir.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: dirPath) else {
                return []
            }

            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [
                        .totalFileAllocatedSizeKey,
                        .contentModificationDateKey,
                    ]
                ).filter { $0.lastPathComponent.hasSuffix(suffix) }

                return files.compactMap { file -> CacheEntry? in
                    let cleanName = file.lastPathComponent
                        .replacingOccurrences(of: suffix, with: "")

                    do {
                        let values = try file.resourceValues(forKeys: [
                            .totalFileAllocatedSizeKey,
                            .contentModificationDateKey,
                        ])
                        let diskSize = UInt64(values.totalFileAllocatedSize ?? 0)
                        let date = values.contentModificationDate ?? Date()
                        let formatter = DateFormatter()
                        formatter.dateStyle = .short
                        formatter.timeStyle = .short
                        return CacheEntry(
                            name: cleanName,
                            diskSize: diskSize,
                            modified: formatter.string(from: date)
                        )
                    } catch {
                        return nil
                    }
                }.sorted { $0.name < $1.name }
            } catch {
                return []
            }
        }

        private func pad(_ s: String, to width: Int) -> String {
            if s.count >= width { return s }
            return s + String(repeating: " ", count: width - s.count)
        }

        private func formatBytes(_ bytes: UInt64) -> String {
            if bytes < 1024 { return "\(bytes) B" }
            let kb = Double(bytes) / 1024
            if kb < 1024 { return String(format: "%.1f KB", kb) }
            let mb = kb / 1024
            if mb < 1024 { return String(format: "%.1f MB", mb) }
            let gb = mb / 1024
            return String(format: "%.1f GB", gb)
        }
    }

    struct CacheRemove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a specific agent cache"
        )

        @Argument(help: "Name of the agent cache to remove")
        var name: String

        func run() async throws {
            _ = try Sandboxy.loadConfig()

            let cacheDir = Sandboxy.appRoot.appendingPathComponent("cache")
            let cachePath = cacheDir.appendingPathComponent("\(name)-rootfs.ext4")

            guard FileManager.default.fileExists(atPath: cachePath.path(percentEncoded: false)) else {
                print("No cache found for agent '\(name)'.")
                throw ExitCode.failure
            }

            try FileManager.default.removeItem(at: cachePath)
            print("Removed cache for '\(name)'.")
        }
    }

    struct CacheClean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Remove all cached rootfs images (use --all to also remove kernel, init image, and content store)"
        )

        @Flag(name: .long, help: "Also remove kernel, init image, and content store, forcing a full re-download on next run")
        var all = false

        @Flag(name: .long, help: "Skip confirmation prompts")
        var yes = false

        func run() async throws {
            _ = try Sandboxy.loadConfig()

            let fm = FileManager.default

            // Check for named instances and warn the user before deleting them.
            let namedDir = InstanceState.namedRootfsDir(appRoot: Sandboxy.appRoot)
            let namedInstances = listNamedInstances(in: namedDir)
            if !namedInstances.isEmpty && !yes {
                print("This will also delete the following named instances:")
                for name in namedInstances {
                    print("  - \(name)")
                }
                print()
                print("Are you sure? [y/N] ", terminator: "")
                guard let response = readLine()?.lowercased(), response == "y" || response == "yes" else {
                    print("Aborted.")
                    return
                }
            }

            let cacheDir = Sandboxy.appRoot.appendingPathComponent("cache")
            if fm.fileExists(atPath: cacheDir.path(percentEncoded: false)) {
                try fm.removeItem(at: cacheDir)
                try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }

            if fm.fileExists(atPath: namedDir.path(percentEncoded: false)) {
                try fm.removeItem(at: namedDir)
                try fm.createDirectory(at: namedDir, withIntermediateDirectories: true)
            }

            if all {
                let kernelDir = Sandboxy.appRoot.appendingPathComponent("kernel")
                if fm.fileExists(atPath: kernelDir.path(percentEncoded: false)) {
                    try fm.removeItem(at: kernelDir)
                    print("Removed kernel.")
                }

                let initfs = Sandboxy.appRoot.appendingPathComponent("initfs.ext4")
                if fm.fileExists(atPath: initfs.path(percentEncoded: false)) {
                    try fm.removeItem(at: initfs)
                    print("Removed init image.")
                }

                let contentDir = Sandboxy.appRoot.appendingPathComponent("content")
                if fm.fileExists(atPath: contentDir.path(percentEncoded: false)) {
                    try fm.removeItem(at: contentDir)
                    print("Removed content store.")
                }

                // Remove the image store reference database so stale references
                // don't point to missing content.
                let stateFile = Sandboxy.appRoot.appendingPathComponent("state.json")
                if fm.fileExists(atPath: stateFile.path(percentEncoded: false)) {
                    try fm.removeItem(at: stateFile)
                }

                print("All caches and downloaded artifacts removed.")
            } else {
                print("All caches removed. Use --all to also remove kernel, init image, and content store.")
            }
        }

        private func listNamedInstances(in dir: URL) -> [String] {
            let path = dir.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                return []
            }
            do {
                return try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                )
                .filter { $0.lastPathComponent.hasSuffix("-rootfs.ext4") }
                .map { $0.lastPathComponent.replacingOccurrences(of: "-rootfs.ext4", with: "") }
                .sorted()
            } catch {
                return []
            }
        }
    }
}
