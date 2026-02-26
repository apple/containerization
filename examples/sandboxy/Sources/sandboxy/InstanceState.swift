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

/// Persistent metadata about a sandbox instance.
struct InstanceState: Codable, Sendable {
    let id: String
    /// User-provided name for persistent instances. Nil for ephemeral runs.
    let name: String?
    let agent: String
    let workspace: String
    let status: Status
    let createdAt: Date
    var stoppedAt: Date?
    let cpus: Int
    let memoryMB: UInt64

    enum Status: String, Codable, Sendable {
        case running
        case stopped
    }

    /// Whether this is a named (persistent) instance.
    var isNamed: Bool { name != nil }

    /// Directory where instance state files are stored.
    static func instancesDir(appRoot: URL) -> URL {
        appRoot.appendingPathComponent("instances")
    }

    /// Directory where named instance rootfs files are preserved.
    static func namedRootfsDir(appRoot: URL) -> URL {
        appRoot.appendingPathComponent("named")
    }

    /// Path to the preserved rootfs for a named instance.
    static func namedRootfsPath(appRoot: URL, name: String) -> URL {
        namedRootfsDir(appRoot: appRoot).appendingPathComponent("\(name)-rootfs.ext4")
    }

    /// Path to this instance's state file.
    func statePath(appRoot: URL) -> URL {
        Self.instancesDir(appRoot: appRoot).appendingPathComponent("\(id).json")
    }

    /// Saves this instance state to disk.
    func save(appRoot: URL) throws {
        let dir = Self.instancesDir(appRoot: appRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: statePath(appRoot: appRoot))
    }

    /// Loads all instance states from disk.
    static func loadAll(appRoot: URL) throws -> [InstanceState] {
        let dir = instancesDir(appRoot: appRoot)
        let path = dir.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        return files.compactMap { file -> InstanceState? in
            do {
                let data = try Data(contentsOf: file)
                return try decoder.decode(InstanceState.self, from: data)
            } catch {
                log.warning("Failed to load instance state from \(file.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    /// Finds a named instance by name.
    static func find(name: String, appRoot: URL) throws -> InstanceState? {
        try loadAll(appRoot: appRoot).first { $0.name == name }
    }

    /// Removes this instance's state file from disk.
    func remove(appRoot: URL) throws {
        try FileManager.default.removeItem(at: statePath(appRoot: appRoot))
    }

    /// Removes this instance's state file and preserved rootfs (for named instances).
    func removeAll(appRoot: URL) throws {
        try remove(appRoot: appRoot)
        if let name {
            let rootfs = Self.namedRootfsPath(appRoot: appRoot, name: name)
            let path = rootfs.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(at: rootfs)
            }
        }
    }
}
