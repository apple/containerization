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

import ContainerizationError
import ContainerizationOCI
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension ImageStore {
    /// A ReferenceManager handles the mappings between an image's
    /// reference and the underlying descriptor inside of a content store.
    internal actor ReferenceManager {
        private let path: URL

        private typealias State = [String: Descriptor]
        private var images: State

        public init(path: URL) throws {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

            self.path = path
            self.images = [:]
        }

        private func load() throws -> State {
            let statePath = self.path.appendingPathComponent("state.json")
            guard FileManager.default.fileExists(atPath: statePath.absolutePath()) else {
                return [:]
            }
            do {
                let data = try Data(contentsOf: statePath)
                let entries = try JSONDecoder().decode([String: SkippableDescriptor].self, from: data)
                return entries.compactMapValues { $0.descriptor }
            } catch {
                throw ContainerizationError(.internalError, message: "failed to load image state \(error.localizedDescription)")
            }
        }

        /// Decodes one state entry, tolerating a record that cannot be read.
        ///
        /// `Descriptor` rejects malformed digests at decode time, so without this
        /// a single unreadable record would make `load()` throw and take every
        /// other image in the store with it — listing, pulling and deleting all
        /// go through here.
        ///
        /// - Note: A skipped record is dropped silently, and because `save()`
        ///   writes back only what `load()` returned, the next mutation removes it
        ///   from `state.json` permanently. That is acceptable because a record
        ///   whose descriptor cannot be decoded is unusable anyway, but it does
        ///   mean the image disappears without a diagnostic.
        private struct SkippableDescriptor: Decodable {
            let descriptor: Descriptor?

            init(from decoder: any Decoder) throws {
                self.descriptor = try? Descriptor(from: decoder)
            }
        }

        private func save(_ state: State) throws {
            let statePath = self.path.appendingPathComponent("state.json")
            try JSONEncoder().encode(state).write(to: statePath, options: .atomic)
        }

        public func delete(reference: String) throws {
            try self.withStateLock {
                var state = try self.load()
                state.removeValue(forKey: reference)
                try self.save(state)
            }
        }

        public func delete(image: Image.Description) throws {
            try self.delete(reference: image.reference)
        }

        public func create(description: Image.Description) throws {
            try self.withStateLock {
                var state = try self.load()
                state[description.reference] = description.descriptor
                try self.save(state)
            }
        }

        /// Serializes read-modify-write of `state.json` across `ImageStore` instances
        /// and processes sharing this directory. `ImageStore.lock` and this actor exist
        /// once per instance, so concurrent writers on separate instances would otherwise
        /// overwrite each other's updates. Because `body` only loads and atomically
        /// saves `state.json` without suspending, blocking in `flock(2)` is bounded.
        private func withStateLock<T>(_ body: () throws -> T) throws -> T {
            let lockPath = self.path.appendingPathComponent("state.json.lock").absolutePath()
            let fd = try Self.openLockFile(lockPath)
            defer {
                close(fd)
            }
            try Self.acquireExclusiveLock(fd, path: lockPath)
            defer {
                _ = flock(fd, LOCK_UN)
            }
            return try body()
        }

        private static func openLockFile(_ path: String) throws -> Int32 {
            while true {
                let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                if fd >= 0 {
                    return fd
                }
                let code = errno
                if code == EINTR {
                    continue
                }
                throw posixError("open \(path)", code)
            }
        }

        private static func acquireExclusiveLock(_ fd: Int32, path: String) throws {
            while flock(fd, LOCK_EX) != 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                throw posixError("lock \(path)", code)
            }
        }

        private static func posixError(_ operation: String, _ code: Int32) -> ContainerizationError {
            let cause = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            return ContainerizationError(.internalError, message: "\(operation) failed: \(cause)", cause: cause)
        }

        public func list() throws -> [Image.Description] {
            let state = try self.load()
            return state.map { key, val in
                let description = Image.Description(reference: key, descriptor: val)
                return description
            }
        }

        public func get(reference: String) throws -> Image.Description {
            let images = try self.list()
            let hit = images.first(where: { image in
                image.reference == reference
            })
            guard let hit else {
                throw ContainerizationError(.notFound, message: "image \(reference) not found")
            }
            return hit
        }
    }
}
