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
import Testing

@testable import Containerization

struct FileMountTests {
    /// Layout: `<root>/a/{f,s}` and `<root>/other/g`.
    private static func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMountTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        try "f".write(to: root.appendingPathComponent("a/f"), atomically: true, encoding: .utf8)
        try "s".write(to: root.appendingPathComponent("a/s"), atomically: true, encoding: .utf8)
        try "g".write(to: root.appendingPathComponent("other/g"), atomically: true, encoding: .utf8)
        return root
    }

    /// The container destinations that survive the holding-tag filter applied when
    /// the OCI spec is built, plus the destinations of the file bind mounts.
    private static func visibleDestinations(_ context: FileMountContext) throws -> Set<String> {
        var destinations = Set<String>()
        for mount in context.transformedMounts {
            let tag = try hashFilePath(path: mount.source)
            if !context.holdingDirectoryTags.contains(tag) {
                destinations.insert(mount.destination)
            }
        }
        for prepared in context.preparedMounts {
            destinations.insert(prepared.containerDestination)
        }
        return destinations
    }

    /// Every file mount must find a share with its tag among the VM's mounts.
    private static func expectFileSharesAttached(_ context: FileMountContext) throws {
        let attachedTags = try Set(context.transformedMounts.map { try hashFilePath(path: $0.source) })
        for prepared in context.preparedMounts {
            #expect(attachedTags.contains(prepared.tag), "no share for \(prepared.hostFilePath)")
        }
    }

    @Test func sameDirectoryAtTwoPaths() throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("a").path

        let context = try FileMountContext.prepare(mounts: [
            .share(source: dir, destination: "/x"),
            .share(source: dir, destination: "/y"),
        ])

        #expect(!context.hasFileMounts)
        #expect(try Self.visibleDestinations(context) == ["/x", "/y"])
    }

    @Test func twoFilesFromSameDirectory() throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try FileMountContext.prepare(mounts: [
            .share(source: root.appendingPathComponent("a/f").path, destination: "/x/f"),
            .share(source: root.appendingPathComponent("a/s").path, destination: "/y/s"),
        ])

        #expect(context.preparedMounts.count == 2)
        #expect(context.transformedMounts.count == 1)
        #expect(context.holdingDirectoryTags == [try hashFilePath(path: root.appendingPathComponent("a").path)])
        #expect(try Self.visibleDestinations(context) == ["/x/f", "/y/s"])
        try Self.expectFileSharesAttached(context)
    }

    @Test(arguments: [false, true])
    func fileFromMountedDirectoryAtUnrelatedPath(fileFirst: Bool) throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = Mount.share(source: root.appendingPathComponent("a").path, destination: "/x")
        let file = Mount.share(source: root.appendingPathComponent("a/f").path, destination: "/z/f")

        let context = try FileMountContext.prepare(mounts: fileFirst ? [file, directory] : [directory, file])

        #expect(context.holdingDirectoryTags.isEmpty)
        #expect(context.transformedMounts.count == 1)
        #expect(try Self.visibleDestinations(context) == ["/x", "/z/f"])
        try Self.expectFileSharesAttached(context)
    }

    @Test func fileFromOtherDirectoryInsideMountedDirectory() throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try FileMountContext.prepare(mounts: [
            .share(source: root.appendingPathComponent("a").path, destination: "/x"),
            .share(source: root.appendingPathComponent("other/g").path, destination: "/x/g"),
        ])

        #expect(context.holdingDirectoryTags == [try hashFilePath(path: root.appendingPathComponent("other").path)])
        #expect(try Self.visibleDestinations(context) == ["/x", "/x/g"])
        try Self.expectFileSharesAttached(context)
    }

    @Test func fileFromSubdirectoryOfMountedDirectory() throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try FileMountContext.prepare(mounts: [
            .share(source: root.path, destination: "/x"),
            .share(source: root.appendingPathComponent("a/f").path, destination: "/x/a/f"),
        ])

        #expect(context.holdingDirectoryTags == [try hashFilePath(path: root.appendingPathComponent("a").path)])
        #expect(try Self.visibleDestinations(context) == ["/x", "/x/a/f"])
        try Self.expectFileSharesAttached(context)
    }
}
