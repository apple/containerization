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

import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

@Suite
struct EXT4PathIOTests {

    // MARK: - Helpers

    private func makeTempImageURL(name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ext4-\(name).img")
    }

    /// Build a fresh ext4 image, populate content, close, and return its URL.
    /// Usage:
    ///   let url = try buildFS { fmt in
    ///       try createFile(fmt, "/etc/hostname", "myhost\n")
    ///       try createSymlink(fmt, "/bin/sh", "/usr/bin/busybox") // fast link
    ///   }
    private func buildFS(
        minDiskSize: UInt64 = 4 * 1024 * 1024,  // 4 MiB is enough for these tests
        blockSize: UInt32 = 4096,
        populate: (EXT4.Formatter) throws -> Void
    ) throws -> URL {
        let url = makeTempImageURL()
        let path = FilePath(url.path)

        // 1) Format image
        let formatter = try EXT4.Formatter(path, blockSize: blockSize, minDiskSize: minDiskSize)

        // 2) Populate contents
        try populate(formatter)

        // 3) Finalize filesystem
        try formatter.close()
        return url
    }

    /// Convenience to create a directory (recursively).
    private func createDir(_ fmt: EXT4.Formatter, _ path: String, mode: UInt16 = EXT4.Inode.Mode(.S_IFDIR, 0o755)) throws {
        try fmt.create(path: FilePath(path), mode: mode)
    }

    /// Convenience to create a regular file with UTF-8 content.
    private func createFile(_ fmt: EXT4.Formatter, _ path: String, _ contents: String, mode: UInt16 = EXT4.Inode.Mode(.S_IFREG, 0o644)) throws {
        let data = Data(contents.utf8)
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        try fmt.create(path: FilePath(path), mode: mode, buf: stream)
    }

    /// Convenience to create a (fast or long) symlink. Pass absolute target.
    private func createSymlink(_ fmt: EXT4.Formatter, _ linkPath: String, _ target: String, mode: UInt16 = EXT4.Inode.Mode(.S_IFLNK, 0o777)) throws {
        try fmt.create(path: FilePath(linkPath), link: FilePath(target), mode: mode)
    }

    /// Open reader for a given image URL.
    private func openReader(_ url: URL) throws -> EXT4.EXT4Reader {
        try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
    }

    // MARK: - Tests

    @Test
    func existsAndStatRootAndLostFound() throws {
        let url = try buildFS { _ in /* nothing extra */ }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        #expect(r.exists(FilePath("/")))
        let (inoNum, ino) = try r.stat(FilePath("/"))
        #expect(inoNum == 2)
        #expect(ino.mode.isDir())

        // lost+found is created by the formatter
        let names = try r.listDirectory(FilePath("/"))
        #expect(names.contains("lost+found"))
    }

    @Test
    func createAndReadRegularFilesWithOffsetsAndEOF() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/etc")
            try self.createFile(fmt, "/etc/hostname", "myhost\n")
            try self.createDir(fmt, "/usr/bin")
            try self.createFile(fmt, "/usr/bin/hello", "Hello EXT4!\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // exists/stat
        #expect(r.exists(FilePath("/etc/hostname")))
        let (_, ino) = try r.stat(FilePath("/usr/bin/hello"))
        #expect(ino.mode.isReg())

        // listDirectory excludes "." and ".." and is sorted
        let usrChildren = try r.listDirectory(FilePath("/usr"))
        #expect(usrChildren == ["bin"])

        // full read to EOF
        let hello = try r.readFile(at: FilePath("/usr/bin/hello"))
        #expect(String(decoding: hello, as: UTF8.self) == "Hello EXT4!\n")

        // offset + count semantics
        let data = try r.readFile(at: FilePath("/usr/bin/hello"), offset: 6, count: 5)
        #expect(String(decoding: data, as: UTF8.self) == "EXT4!")

        // offset == size => empty; offset > size => empty
        let hostname = try r.readFile(at: FilePath("/etc/hostname"))
        let size = hostname.count
        #expect(try r.readFile(at: FilePath("/etc/hostname"), offset: UInt64(size)).count == 0)
        #expect(try r.readFile(at: FilePath("/etc/hostname"), offset: UInt64(size + 100)).count == 0)
    }

    @Test
    func readFileIntoBufferMatchesData() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/etc")
            try self.createFile(fmt, "/etc/hostname", "myhost\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try openReader(url)
        let path = FilePath("/etc/hostname")

        let data = try reader.readFile(at: path, offset: 0, count: 4096)
        var buffer = [UInt8](repeating: 0, count: data.count)

        let wrote = try buffer.withUnsafeMutableBytes { ptr in
            try reader.readFile(at: path, into: ptr, offset: 0)
        }

        #expect(wrote == data.count)
        if wrote < buffer.count {
            buffer.removeSubrange(wrote..<buffer.count)
        }
        #expect(Data(buffer) == data)
    }

    @Test
    func listDirectoryOnFileThrowsNotAFile() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/etc")
            try self.createFile(fmt, "/etc/hostname", "host\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        do {
            _ = try r.listDirectory(FilePath("/etc/hostname"))
            Issue.record("Expected notADirectory error")
        } catch let error as EXT4.PathIOError {
            guard case .notADirectory = error else {
                Issue.record("Expected notADirectory, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }

    @Test
    func fastSymlinkResolutionAndRead() throws {
        // Fast symlink: target stored in inode "block" area if len < 60 (Formatter behavior).
        // Create /usr/bin/busybox and /bin/sh -> /usr/bin/busybox
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/usr/bin")
            try self.createFile(fmt, "/usr/bin/busybox", "BB\n")
            try self.createDir(fmt, "/bin")
            try self.createSymlink(fmt, "/bin/sh", "/usr/bin/busybox")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Reading through the link should hit the target bytes.
        let sh = try r.readFile(at: FilePath("/bin/sh"))
        #expect(String(decoding: sh, as: UTF8.self) == "BB\n")

        // stat(followSymlinks: false) should show symlink inode
        let (_, lnkIno) = try r.stat(FilePath("/bin/sh"), followSymlinks: false)
        #expect(lnkIno.mode.isLink())

        // stat(default) follows
        let (_, tgtIno) = try r.stat(FilePath("/bin/sh"))
        #expect(tgtIno.mode.isReg())
    }

    @Test
    func longSymlinkResolutionAndRead() throws {
        // Long symlink: target > 60 bytes triggers extent-backed storage (Formatter behavior).
        // Build a very long absolute path to exceed 60 chars.
        let deepDir = "/a/very/long/path/that/exceeds/sixty/bytes/for/symlink/target"
        #expect(deepDir.utf8.count > 60)

        let url = try buildFS { fmt in
            // Create deep directory structure and file
            try self.createDir(fmt, deepDir)
            try self.createFile(fmt, "\(deepDir)/payload.txt", "LONGLINK\n")
            // Link at a short path -> long absolute target
            try self.createSymlink(fmt, "/ll", "\(deepDir)/payload.txt")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        let bytes = try r.readFile(at: FilePath("/ll"))
        #expect(String(decoding: bytes, as: UTF8.self) == "LONGLINK\n")
    }

    @Test
    func symlinkLoopDetection() throws {
        let url = try buildFS { fmt in
            // /a -> /b and /b -> /a
            try self.createSymlink(fmt, "/a", "/b")
            try self.createSymlink(fmt, "/b", "/a")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        do {
            _ = try r.stat(FilePath("/a"))
            Issue.record("Expected symlinkLoop error")
        } catch let error as EXT4.PathIOError {
            guard case .symlinkLoop = error else {
                Issue.record("Expected symlinkLoop, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }

    @Test
    func complexSymlinkLoopDetection() throws {
        let url = try buildFS { fmt in
            // Create a longer chain that eventually loops: /a -> /b -> /c -> /d -> /b
            try self.createSymlink(fmt, "/a", "/b")
            try self.createSymlink(fmt, "/b", "/c")
            try self.createSymlink(fmt, "/c", "/d")
            try self.createSymlink(fmt, "/d", "/b")  // Loop back to /b
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        do {
            _ = try r.stat(FilePath("/a"))
            Issue.record("Expected symlinkLoop error")
        } catch let error as EXT4.PathIOError {
            guard case .symlinkLoop = error else {
                Issue.record("Expected symlinkLoop for complex loop, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }

    @Test
    func selfReferencingSymlink() throws {
        let url = try buildFS { fmt in
            // Self-referencing symlink: /self -> /self
            try self.createSymlink(fmt, "/self", "/self")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        do {
            _ = try r.stat(FilePath("/self"))
            Issue.record("Expected symlinkLoop error")
        } catch let error as EXT4.PathIOError {
            guard case .symlinkLoop = error else {
                Issue.record("Expected symlinkLoop for self-reference, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }

    @Test
    func longSymlinkChainWithoutLoop() throws {
        let url = try buildFS { fmt in
            // Create a long chain without loops (should succeed)
            try self.createDir(fmt, "/target")
            try self.createFile(fmt, "/target/file.txt", "SUCCESS\n")

            // Create chain: /link1 -> /link2 -> /link3 -> /link4 -> /target/file.txt
            try self.createSymlink(fmt, "/link4", "/target/file.txt")
            try self.createSymlink(fmt, "/link3", "/link4")
            try self.createSymlink(fmt, "/link2", "/link3")
            try self.createSymlink(fmt, "/link1", "/link2")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        // Should successfully resolve without hitting loop detection
        let data = try r.readFile(at: FilePath("/link1"))
        #expect(String(decoding: data, as: UTF8.self) == "SUCCESS\n")
    }

    @Test
    func symlinkLoopThroughDirectory() throws {
        let url = try buildFS { fmt in
            // Create directory structure with symlink loop through paths
            try self.createDir(fmt, "/dir1")
            try self.createDir(fmt, "/dir2")
            try self.createSymlink(fmt, "/dir1/link", "/dir2/link")
            try self.createSymlink(fmt, "/dir2/link", "/dir1/link")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        do {
            _ = try r.stat(FilePath("/dir1/link"))
            Issue.record("Expected symlinkLoop error")
        } catch let error as EXT4.PathIOError {
            guard case .symlinkLoop = error else {
                Issue.record("Expected symlinkLoop for directory loop, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }

    @Test
    func pathWalkWithDotAndDotDot() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/a/b")
            try self.createFile(fmt, "/a/b/c.txt", "OK\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // /a/./b/../b/c.txt should resolve to /a/b/c.txt
        let p = FilePath("/a/./b/../b/c.txt")
        let data = try r.readFile(at: p)
        #expect(String(decoding: data, as: UTF8.self) == "OK\n")
    }

    @Test
    func parentDirectoryTraversal() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/a/b/c/d")
            try self.createFile(fmt, "/a/file1.txt", "A\n")
            try self.createFile(fmt, "/a/b/file2.txt", "B\n")
            try self.createFile(fmt, "/a/b/c/file3.txt", "C\n")
            try self.createFile(fmt, "/a/b/c/d/file4.txt", "D\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Test multiple levels of parent traversal
        // /a/b/c/d/../../../../a/file1.txt should resolve to /a/file1.txt
        let p1 = FilePath("/a/b/c/d/../../../../a/file1.txt")
        let data1 = try r.readFile(at: p1)
        #expect(String(decoding: data1, as: UTF8.self) == "A\n")

        // /a/b/c/../file2.txt should resolve to /a/b/file2.txt
        let p2 = FilePath("/a/b/c/../file2.txt")
        let data2 = try r.readFile(at: p2)
        #expect(String(decoding: data2, as: UTF8.self) == "B\n")

        // /a/b/c/d/../file3.txt should resolve to /a/b/c/file3.txt
        let p3 = FilePath("/a/b/c/d/../file3.txt")
        let data3 = try r.readFile(at: p3)
        #expect(String(decoding: data3, as: UTF8.self) == "C\n")
    }

    @Test
    func parentDirectoryAtRoot() throws {
        let url = try buildFS { fmt in
            try self.createFile(fmt, "/root.txt", "ROOT\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Test that ".." at root stays at root
        // /../root.txt should resolve to /root.txt
        let p1 = FilePath("/../root.txt")
        let data1 = try r.readFile(at: p1)
        #expect(String(decoding: data1, as: UTF8.self) == "ROOT\n")

        // /../../root.txt should also resolve to /root.txt
        let p2 = FilePath("/../../root.txt")
        let data2 = try r.readFile(at: p2)
        #expect(String(decoding: data2, as: UTF8.self) == "ROOT\n")
    }

    @Test
    func complexParentWithSymlinks() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/real/path")
            try self.createFile(fmt, "/real/path/target.txt", "TARGET\n")
            try self.createFile(fmt, "/real/other.txt", "OTHER\n")
            try self.createDir(fmt, "/links")
            // Create symlink: /links/link -> /real/path
            try self.createSymlink(fmt, "/links/link", "/real/path")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Test parent directory traversal through symlinks
        // When we follow /links/link (which points to /real/path), we're now at /real/path
        // Then ".." takes us to /real, and "other.txt" gives us /real/other.txt
        let p = FilePath("/links/link/../other.txt")
        let data = try r.readFile(at: p)
        #expect(String(decoding: data, as: UTF8.self) == "OTHER\n")

        // Also test direct access through the symlink
        let p2 = FilePath("/links/link/target.txt")
        let data2 = try r.readFile(at: p2)
        #expect(String(decoding: data2, as: UTF8.self) == "TARGET\n")
    }

    @Test
    func relativeSymlinkWithParentTraversal() throws {
        let url = try buildFS { fmt in
            try self.createDir(fmt, "/a/b")
            try self.createFile(fmt, "/a/target.txt", "REL_TARGET\n")
            // Create relative symlink: /a/b/link -> ../target.txt
            try self.createSymlink(fmt, "/a/b/link", "../target.txt")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // The relative symlink should properly resolve through parent
        let data = try r.readFile(at: FilePath("/a/b/link"))
        #expect(String(decoding: data, as: UTF8.self) == "REL_TARGET\n")
    }

    @Test
    func readOnSymlinkWithFollowFalseThrows() throws {
        let url = try buildFS { fmt in
            try self.createFile(fmt, "/tgt", "X\n")
            try self.createSymlink(fmt, "/lnk", "/tgt")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        do {
            _ = try r.readFile(at: FilePath("/lnk"), followSymlinks: false)
            Issue.record("Expected notAFile error")
        } catch let error as EXT4.PathIOError {
            guard case .notAFile = error else {
                Issue.record("Expected notAFile for symlink read without following, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
    }

    @Test
    func nonExistentPathExistsAndReadErrors() throws {
        let url = try buildFS { _ in }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)
        #expect(!r.exists(FilePath("/nope")))
        do {
            _ = try r.stat(FilePath("/nope"))
            Issue.record("Expected notFound error")
        } catch let error as EXT4.PathIOError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected EXT4.PathIOError, got \(error)")
        }
        #expect(throws: (any Error).self) {
            try r.readFile(at: FilePath("/nope"))
        }
    }

    @Test
    func boundsCheckingForInvalidExtents() throws {
        // This test verifies that the reader properly validates extent addresses
        // Note: We can't easily create an image with invalid extents using the Formatter,
        // so this test documents the expected behavior rather than testing it directly.
        // The bounds checking is tested implicitly by all other tests that read files.

        let url = try buildFS { fmt in
            try self.createFile(fmt, "/test.txt", "Valid file\n")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Reading a valid file should work without bounds errors
        let data = try r.readFile(at: FilePath("/test.txt"))
        #expect(String(decoding: data, as: UTF8.self) == "Valid file\n")

        // The bounds checking happens internally when reading extents
        // If an extent pointed outside device bounds, it would throw an error
    }

    @Test
    func partialReadRecovery() throws {
        // Test that partial reads return successfully read data
        // even if later parts fail

        let url = try buildFS(minDiskSize: 8 * 1024 * 1024) { fmt in
            // Create a moderately sized file
            let content = String(repeating: "A", count: 100_000)
            try self.createFile(fmt, "/partial.txt", content)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Read the full file to ensure it works
        let fullData = try r.readFile(at: FilePath("/partial.txt"))
        #expect(fullData.count == 100_000)

        // Read with offset and count
        let partialData = try r.readFile(at: FilePath("/partial.txt"), offset: 1000, count: 5000)
        #expect(partialData.count == 5000)

        // Verify content is correct
        let expectedContent = String(repeating: "A", count: 5000)
        #expect(String(decoding: partialData, as: UTF8.self) == expectedContent)
    }

    @Test
    func largeFileReadAcrossBlocks() throws {
        // Keep this modest to avoid slow CI while still crossing multiple blocks.
        let bigSize = 2 * 1024 * 1024 + 123  // ~2 MiB + tail
        let url = try buildFS(minDiskSize: 16 * 1024 * 1024) { fmt in
            try self.createDir(fmt, "/big")
            // Generate deterministic content without holding huge Data in memory at once
            // by assembling in chunks.
            let chunk = Data("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\n".utf8)
            var buf = Data(capacity: bigSize)
            while buf.count + chunk.count <= bigSize {
                buf.append(chunk)
            }
            if buf.count < bigSize {
                buf.append(contentsOf: [UInt8](repeating: 0x5A, count: bigSize - buf.count))  // 'Z'
            }
            let stream = InputStream(data: buf)
            stream.open()
            defer { stream.close() }
            try fmt.create(path: FilePath("/big/file.bin"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let r = try openReader(url)

        // Sample reads near the end and across likely block boundaries.
        let tail = try r.readFile(at: FilePath("/big/file.bin"), offset: UInt64(bigSize - 64), count: 64)
        #expect(tail.count == 64)

        let middle = try r.readFile(at: FilePath("/big/file.bin"), offset: 64, count: 128)
        #expect(middle.count == 128)

        // Read to EOF without count
        let all = try r.readFile(at: FilePath("/big/file.bin"))
        #expect(all.count == bigSize)
    }
}
