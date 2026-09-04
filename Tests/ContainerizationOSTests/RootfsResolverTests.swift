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

// openat2(RESOLVE_IN_ROOT) is Linux-only, so these tests only build and run there.
#if os(Linux)

import Foundation
import Testing

@testable import ContainerizationOS

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

struct RootfsResolverTests {
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

    private func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    @Test func opensFileWithinRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent("sub"), withIntermediateDirectories: true)
        let content = Data("hello".utf8)
        try content.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("sub/file.txt")))

        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        let fd = RootfsResolver.openInRoot(dirFd: rootFd, path: "sub/file.txt", flags: O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(readAll(fd) == content)
    }

    @Test func doesNotFollowAbsoluteSymlinkOutsideRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: outside) }

        let secret = (outside as NSString).appendingPathComponent("secret.txt")
        try Data("top-secret".utf8).write(to: URL(fileURLWithPath: secret))
        try FileManager.default.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("escape"),
            withDestinationPath: secret
        )

        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        // Absolute symlink targets are reinterpreted under root, so this should fail with ENOENT.
        let fd = RootfsResolver.openInRoot(dirFd: rootFd, path: "escape", flags: O_RDONLY)
        let err = errno
        if fd >= 0 { close(fd) }
        #expect(fd == -1, "openInRoot escaped the root via an absolute symlink")
        #expect(err == ENOENT)
    }

    @Test func clampsParentTraversalToRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let content = Data("marker".utf8)
        try content.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("marker.txt")))

        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        // ".." is clamped at the root, so this resolves back to <root>/marker.txt.
        let fd = RootfsResolver.openInRoot(dirFd: rootFd, path: "../../../marker.txt", flags: O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(readAll(fd) == content)
    }

    @Test func createsNestedDirectoriesWithinRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        try RootfsResolver.createDirectoryInRoot(dirFd: rootFd, path: "a/b/c")

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("a/b/c"), isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func createDirectoryDoesNotEscapeViaAbsoluteSymlink() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: outside) }

        try FileManager.default.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("escape"),
            withDestinationPath: outside
        )

        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        // The absolute symlink is confined to a nonexistent in-root path.
        #expect(throws: RootfsResolver.Error.self) {
            try RootfsResolver.createDirectoryInRoot(dirFd: rootFd, path: "escape/planted")
        }
        #expect(!FileManager.default.fileExists(atPath: (outside as NSString).appendingPathComponent("planted")))
    }

    @Test func createDirectoryRejectsEmbeddedNul() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let rootFd = try openRoot(root)
        defer { close(rootFd) }

        // Reject before mkdirat/openat can truncate this into "new/a".
        #expect(throws: RootfsResolver.Error.self) {
            try RootfsResolver.createDirectoryInRoot(dirFd: rootFd, path: "new/a\u{0}b")
        }
        #expect(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("new")))
    }

    @Test func doesNotTraverseProcMagicLink() throws {
        // /proc/<pid>/fd/<n> is a magic link; RESOLVE_NO_MAGICLINKS should reject it.
        let procFd = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(procFd >= 0)
        defer { close(procFd) }
        let pid = getpid()

        // Address a descriptor the test owns (procFd) so the entry is guaranteed open.
        let magic = RootfsResolver.openInRoot(dirFd: procFd, path: "\(pid)/fd/\(procFd)", flags: O_RDONLY)
        let err = errno
        if magic >= 0 { close(magic) }
        #expect(magic == -1, "openInRoot traversed a /proc magic link")
        #expect(err == ELOOP)

        // Positive control: /proc itself is readable.
        let regular = RootfsResolver.openInRoot(dirFd: procFd, path: "\(pid)/stat", flags: O_RDONLY)
        if regular >= 0 { close(regular) }
        #expect(regular >= 0)
    }
}

#endif
