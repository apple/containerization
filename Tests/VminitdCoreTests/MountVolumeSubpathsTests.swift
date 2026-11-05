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

#if os(Linux)

import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import Testing

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

@testable import VminitdCore

/// Staging binds for real, so the tests that stage need CAP_SYS_ADMIN and are skipped without it.
struct MountVolumeSubpathsTests {
    private let log = Logger(label: "MountVolumeSubpathsTests")

    private static let canBind: Bool = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (from, to) = (dir.appending(path: "from").path, dir.appending(path: "to").path)
        guard (try? FileManager.default.createDirectory(atPath: from, withIntermediateDirectories: true)) != nil,
            (try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)) != nil,
            mount(from, to, nil, UInt(MS_BIND), nil) == 0
        else {
            return false
        }
        umount2(to, Int32(MNT_DETACH))
        return true
    }()

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spec(_ mounts: [ContainerizationOCI.Mount]) -> ContainerizationOCI.Spec {
        var spec = ContainerizationOCI.Spec()
        spec.mounts = mounts
        return spec
    }

    private func isMounted(_ path: String) throws -> Bool {
        try String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8)
            .split(separator: "\n")
            .contains { $0.split(separator: " ").dropFirst(4).first == Substring(path) }
    }

    @Test(.enabled(if: canBind))
    func stagesSubpathMountsAndRewritesThem() throws {
        let volume = try makeTempDirectory()
        let staging = try makeTempDirectory()
        defer {
            MountVolumeSubpaths.remove(id: "ctr", root: staging, log: log)
            try? FileManager.default.removeItem(at: volume)
            try? FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.createDirectory(at: volume.appending(path: "a"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: volume.appending(path: "a/file"))

        var spec = spec([
            .init(type: "none", source: volume.path, destination: "/whole", options: ["bind"]),
            .init(type: "none", source: volume.path, destination: "/dir", options: ["bind", "ro", VolumeSubpath.toMountOption("a/b/c")]),
            .init(type: "none", source: volume.path, destination: "/file", options: ["bind", VolumeSubpath.toMountOption("a/file")]),
        ])
        try MountVolumeSubpaths.stage(id: "ctr", spec: &spec, root: staging, log: log)

        let dir = staging.appending(path: "ctr").path
        #expect(spec.mounts[0].source == volume.path)
        #expect(spec.mounts[0].options == ["bind"])
        // The staging name counts the staged mounts, not the spec position.
        #expect(spec.mounts[1].source == dir + "/0")
        #expect(spec.mounts[1].options == ["bind", "ro"])
        #expect(spec.mounts[2].source == dir + "/1")
        #expect(spec.mounts[2].options == ["bind"])

        // The missing directories were made in the volume, and each staging path is a bind of
        // what the subpath names.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: volume.path + "/a/b/c", isDirectory: &isDir) && isDir.boolValue)
        #expect(try isMounted(dir + "/0"))
        #expect(try isMounted(dir + "/1"))
        try Data("via-staging".utf8).write(to: URL(fileURLWithPath: dir + "/0/marker"))
        #expect(FileManager.default.fileExists(atPath: volume.path + "/a/b/c/marker"))
        #expect(try String(contentsOfFile: dir + "/1", encoding: .utf8) == "x")

        MountVolumeSubpaths.remove(id: "ctr", root: staging, log: log)
        #expect(try !isMounted(dir + "/0"))
        #expect(try !isMounted(dir + "/1"))
        #expect(!FileManager.default.fileExists(atPath: dir))
        // The volume keeps its data.
        #expect(FileManager.default.fileExists(atPath: volume.path + "/a/b/c/marker"))
        #expect(FileManager.default.fileExists(atPath: volume.path + "/a/file"))
    }

    @Test(.enabled(if: canBind))
    func aFailureRemovesWhatWasStaged() throws {
        let volume = try makeTempDirectory()
        let staging = try makeTempDirectory()
        defer {
            MountVolumeSubpaths.remove(id: "ctr", root: staging, log: log)
            try? FileManager.default.removeItem(at: volume)
            try? FileManager.default.removeItem(at: staging)
        }
        try Data("x".utf8).write(to: volume.appending(path: "file"))

        var spec = spec([
            .init(type: "none", source: volume.path, destination: "/ok", options: ["bind", VolumeSubpath.toMountOption("ok")]),
            .init(type: "none", source: volume.path, destination: "/bad", options: ["bind", VolumeSubpath.toMountOption("file/x")]),
        ])
        #expect(throws: (any Error).self) {
            try MountVolumeSubpaths.stage(id: "ctr", spec: &spec, root: staging, log: log)
        }
        // The first mount was bound, then detached and deleted when the second failed.
        #expect(FileManager.default.fileExists(atPath: volume.path + "/ok"))
        #expect(try !isMounted(staging.appending(path: "ctr/0").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: "ctr").path))
    }
}

#endif
