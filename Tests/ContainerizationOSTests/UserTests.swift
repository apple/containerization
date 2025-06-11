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

import ContainerizationError
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerizationOS

@Suite("User/Group parse tests")
final class UsersTests {
    struct TestCase: Sendable {
        let userString: String
        let expect: User.ExecUser
        let shouldThrow: Bool

        init(_ userString: String, _ expect: User.ExecUser, _ shouldThrow: Bool) {
            self.userString = userString
            self.expect = expect
            self.shouldThrow = shouldThrow
        }
    }

    static func createFile(path: URL, content: Data) throws {
        let parent = path.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: path)
    }

    @Test
    func testOnlyPasswd() throws {
        let passwordContent = """
            root:x:0:0:root:/root:/bin/bash
            daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
            bin:x:2:2:bin:/bin:/usr/sbin/nologin
            sys:x:3:3:sys:/dev:/usr/sbin/nologin
            nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
            platform:x:1000:1000:Platform:/home/platform:/bin/sh
            """

        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer { try? fileManager.removeItem(at: tempDir) }
        let passwdPath = tempDir.appending(path: "etc/passwd")
        try Self.createFile(path: passwdPath, content: passwordContent.data(using: .ascii)!)

        let testCases: [TestCase] = [
            .init("root", .init(uid: 0, gid: 0, sgids: [0], home: "/root"), false),
            .init("0:0", .init(uid: 0, gid: 0, sgids: [0], home: "/root"), false),
            .init("platform", .init(uid: 1000, gid: 1000, sgids: [1000], home: "/home/platform"), false),
            .init("65534", .init(uid: 65534, gid: 65534, sgids: [65534], home: "/nonexistent"), false),
            .init("should_fail", .init(uid: 456, gid: 123, sgids: [9999], home: "/undefined"), true),
            .init(":nouser", .init(uid: 456, gid: 123, sgids: [9999], home: "/undefined"), true),
        ]

        for testCase in testCases {
            if testCase.shouldThrow {
                #expect(throws: ContainerizationError.self) {
                    try User.parseUser(root: tempDir.absolutePath(), userString: testCase.userString)
                }
                continue
            }
            let user = try User.parseUser(root: tempDir.absolutePath(), userString: testCase.userString)
            #expect(testCase.expect.uid == user.uid)
            #expect(testCase.expect.gid == user.gid)
            #expect(testCase.expect.home == user.home)
            #expect(testCase.expect.sgids == user.sgids)
        }
    }

    @Test(arguments: [
        TestCase("foobar", .init(uid: 0, gid: 0, sgids: [0], home: "/root"), true),
        TestCase("101:101", .init(uid: 101, gid: 101, sgids: [], home: "/"), false),
        TestCase("1025:must-fail", .init(uid: 0, gid: 0, sgids: [], home: "/"), true),
    ])
    func testNoPasswd(testCase: TestCase) throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        if testCase.shouldThrow {
            #expect(throws: ContainerizationError.self) {
                try User.parseUser(root: tempDir.absolutePath(), userString: testCase.userString)
            }
        } else {
            let parsed = try User.parseUser(root: tempDir.absolutePath(), userString: testCase.userString)
            #expect(testCase.expect.uid == parsed.uid)
            #expect(testCase.expect.gid == parsed.gid)
            #expect(testCase.expect.home == parsed.home)
            #expect(testCase.expect.sgids == parsed.sgids)
        }
    }

    @Test
    func testPasswdGroup() throws {
        let passwordContent = """
            root:x:0:0:root:/root:/bin/bash
            daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
            bin:x:2:2:bin:/bin:/usr/sbin/nologin
            sys:x:3:3:sys:/dev:/usr/sbin/nologin
            backup:x:34:34:backup:/var/backups:/usr/sbin/nologin
            nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
            platform:x:1000:1000:platform:/home/platform:/bin/bash
            """

        let groupContent = """
            root:x:0:
            daemon:x:1:
            bin:x:2:
            adm:x:4:platform
            tape:x:26:
            sudo:x:27:platform
            audio:x:29:platform
            video:x:44:platform
            nogroup:x:65534:
            platform:x:1000:
            """

        let fileManager = FileManager.default
        let tempDir = fileManager.uniqueTemporaryDirectory()
        defer { try? fileManager.removeItem(at: tempDir) }
        let passwdPath = tempDir.appending(path: "etc/passwd")
        let groupPath = tempDir.appending(path: "etc/group")
        try Self.createFile(path: passwdPath, content: passwordContent.data(using: .ascii)!)
        try Self.createFile(path: groupPath, content: groupContent.data(using: .ascii)!)

        let testCases: [TestCase] = [
            .init("root:bin", .init(uid: 0, gid: 2, sgids: [2], home: "/root"), false),
            .init("daemon:platform", .init(uid: 1, gid: 1000, sgids: [1000], home: "/usr/sbin"), false),
            .init("platform", .init(uid: 1000, gid: 1000, sgids: [4, 27, 29, 44, 1000], home: "/home/platform"), false),
            .init("nobody", .init(uid: 65534, gid: 65534, sgids: [65534], home: "/nonexistent"), false),
            .init("2:1000", .init(uid: 2, gid: 1000, sgids: [1000], home: "/bin"), false),
        ]

        for testCase in testCases {
            if testCase.shouldThrow {
                #expect(throws: ContainerizationError.self) {
                    try User.parseUser(root: tempDir.absolutePath(), userString: testCase.userString)
                }
            }
            let user = try User.parseUser(root: tempDir.absolutePath(), userString: testCase.userString)
            #expect(testCase.expect.uid == user.uid)
            #expect(testCase.expect.gid == user.gid)
            #expect(testCase.expect.home == user.home)
            #expect(Set(testCase.expect.sgids) == Set(user.sgids))
        }
    }
}
