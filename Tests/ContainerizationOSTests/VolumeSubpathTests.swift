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

@testable import ContainerizationOS

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

struct VolumeSubpathTests {
    /// A `nil` subpath means the options carry none, which is an error.
    @Test(
        arguments: [
            (["ro", VolumeSubpath.toMountOption("a/b"), "nosuid"], "a/b", ["ro", "nosuid"]),
            (["bind", "ro"], nil, []),
        ] as [([String], String?, [String])])
    func extractsTheSubpath(options: [String], subpath: String?, rest: [String]) throws {
        guard let subpath else {
            #expect(throws: VolumeSubpath.Error.missing(options: options)) {
                try VolumeSubpath.extract(from: options)
            }
            return
        }

        let extracted = try VolumeSubpath.extract(from: options)
        #expect(extracted.subpath == subpath)
        #expect(extracted.options == rest)
    }

    @Test func aRepeatedSubpathIsAnError() {
        let options = ["bind", VolumeSubpath.toMountOption("a"), VolumeSubpath.toMountOption("b")]
        #expect(throws: VolumeSubpath.Error.invalid(subpath: "b", reason: "it is given more than once")) {
            try VolumeSubpath.extract(from: options)
        }
    }

    @Test(arguments: [
        (["bind", VolumeSubpath.toMountOption("a")], true),
        (["bind", "ro", VolumeSubpath.toMountOption("a")], true),
        (["bind"], false),
        (["ro"], false),
    ])
    func detectsSubpathMounts(options: [String], expected: Bool) throws {
        #expect(try VolumeSubpath.isSubpathMount(options: options) == expected)
    }

    @Test(arguments: [["ro"], ["rbind"], ["bind", "rbind"]])
    func aSubpathOnANonBindMountIsAnError(options: [String]) {
        #expect(throws: VolumeSubpath.Error.notBind) {
            try VolumeSubpath.isSubpathMount(options: options + [VolumeSubpath.toMountOption("a")])
        }
    }

    @Test func componentsDropEmptyAndCurrentNames() throws {
        #expect(try VolumeSubpath.components(of: "a") == ["a"])
        #expect(try VolumeSubpath.components(of: "a/b/c") == ["a", "b", "c"])
        #expect(try VolumeSubpath.components(of: "a//b/") == ["a", "b"])
        #expect(try VolumeSubpath.components(of: "a/./b") == ["a", "b"])
        #expect(try VolumeSubpath.components(of: "./a") == ["a"])
        #expect(try VolumeSubpath.components(of: "a/.") == ["a"])
        #expect(try VolumeSubpath.components(of: "with space/..x") == ["with space", "..x"])
    }

    @Test(arguments: ["", "/", "//", "/a", ".", "./", "..", "a/..", "../a", "a/../b", "a\0b"])
    func invalidSubpathsAreRejected(subpath: String) {
        #expect(throws: VolumeSubpath.Error.self) {
            try VolumeSubpath.components(of: subpath)
        }
    }

    #if os(Linux)
    private func makeTempDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func openRoot(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        return fd
    }

    /// The path the kernel reports for `fd`.
    private func path(of fd: Int32) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")
    }

    @Test func opensAnExistingDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        let fd = try VolumeSubpath.open(beneath: rootFd, subpath: "a/b")
        defer { close(fd) }
        #expect(try path(of: fd) == root + "/a/b")
    }

    @Test func opensAnExistingFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/file"))
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        let fd = try VolumeSubpath.open(beneath: rootFd, subpath: "file")
        defer { close(fd) }
        #expect(try path(of: fd) == root + "/file")
    }

    @Test func createsMissingDirectories() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        let fd = try VolumeSubpath.open(beneath: rootFd, subpath: "a/b/c")
        defer { close(fd) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root + "/a/b/c", isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(try path(of: fd) == root + "/a/b/c")
    }

    /// A root holding `real` and links to it: relative, upward, absolute, and escaping.
    private func makeRootWithLinks() throws -> String {
        let root = try makeTempDirectory()
        try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/alias", withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: root + "/a/up", withDestinationPath: "../real")
        try FileManager.default.createSymbolicLink(atPath: root + "/abs", withDestinationPath: "/real")
        try FileManager.default.createSymbolicLink(atPath: root + "/escape", withDestinationPath: "../../../..")
        return root
    }

    @Test(arguments: ["alias", "a/up"])
    func followsSymlinksWithinTheRoot(subpath: String) throws {
        let root = try makeRootWithLinks()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        let fd = try VolumeSubpath.open(beneath: rootFd, subpath: subpath)
        defer { close(fd) }
        #expect(try path(of: fd) == root + "/real")
    }

    /// As in Kubernetes, a link that leaves the volume fails instead of being re-rooted.
    @Test(arguments: ["abs", "escape/real", "abs/new"])
    func aSymlinkLeavingTheRootIsAnError(subpath: String) throws {
        let root = try makeRootWithLinks()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        #expect(throws: VolumeSubpath.Error.resolve(subpath: subpath, errno: EXDEV)) {
            let fd = try VolumeSubpath.open(beneath: rootFd, subpath: subpath)
            close(fd)
        }
    }

    @Test func aDanglingSymlinkIsAnError() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling", withDestinationPath: "missing")
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        #expect(throws: VolumeSubpath.Error.self) {
            let fd = try VolumeSubpath.open(beneath: rootFd, subpath: "dangling/below")
            close(fd)
        }
    }

    @Test func aFileInTheMiddleIsAnError() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/file"))
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        #expect(throws: VolumeSubpath.Error.self) {
            let fd = try VolumeSubpath.open(beneath: rootFd, subpath: "file/below")
            close(fd)
        }
    }
    #endif
}
