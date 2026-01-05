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

//  swiftlint:disable force_try

import Foundation
import Testing

@testable import ContainerizationEXT4

struct TestEXT4ExtendedAttribute {
    @Test func compressName() {
        struct TestCase {
            let input: String
            let expectedId: UInt8
            let expectedStr: String
            init(_ input: String, _ expectedId: UInt8, _ expectedStr: String) {
                self.input = input
                self.expectedId = expectedId
                self.expectedStr = expectedStr
            }
        }
        let tests: [TestCase] = [
            .init("my.test.xattr", 0, "my.test.xattr"),
            .init("user.fubar", 1, "fubar"),
            .init("system.posix_acl_access.denied_su", 2, ".denied_su"),
            .init("system.posix_acl_default_failed", 3, "_failed"),
            .init("trusted.user", 4, "user"),
            .init("trusted_user", 0, "trusted_user"),
            .init("security.auth", 6, "auth"),
            .init("system.admin", 7, "admin"),
            .init("system.richacl.denied", 8, ".denied"),
        ]
        for test in tests {
            let ret = EXT4.ExtendedAttribute.compressName(test.input)
            #expect(ret.0 == test.expectedId)
            #expect(ret.1 == test.expectedStr)
        }
    }

    @Test func encodeDecodeAttributes() {
        let xattrs: [String: Data] = [
            "foo.bar": Data([1, 2, 3]),
            "bar": Data([0, 0, 0]),
            "system.richacl.bar": Data([99, 1, 9, 1]),
            "foobar.user": Data([71, 2, 45]),
            "test.xattr.cap": Data([1, 32, 3]),
            "testing123": Data([12, 24, 45]),
            "sys.admin": Data([16, 23, 13]),
            "test.123": Data([15, 26, 54]),
            "extendedattribute.test": Data([15, 26, 54, 1, 2, 4, 6, 7, 7]),
        ]
        let blockSize = 4096
        var state = EXT4.FileXattrsState(
            inode: 1, inodeXattrCapacity: EXT4.InodeExtraSize, blockCapacity: UInt32(blockSize))
        for (s, d) in xattrs {
            let attribute = EXT4.ExtendedAttribute(name: s, value: [UInt8](d))
            try! state.add(attribute)
        }
        var inlineAttrBuffer: [UInt8] = .init(repeating: 0, count: Int(EXT4.InodeExtraSize))
        var blockAttrBuffer: [UInt8] = .init(repeating: 0, count: blockSize)
        try! state.writeInlineAttributes(buffer: &inlineAttrBuffer)
        try! state.writeBlockAttributes(buffer: &blockAttrBuffer)
        let gotInlineXattrs = try! EXT4.EXT4Reader.readInlineExtendedAttributes(from: inlineAttrBuffer)
        let gotBlockXattrs = try! EXT4.EXT4Reader.readBlockExtendedAttributes(from: blockAttrBuffer)

        var gotXattrs: [String: Data] = [:]
        for attr in gotBlockXattrs + gotInlineXattrs {
            gotXattrs[attr.fullName] = Data(attr.value)
        }
        #expect(gotXattrs == xattrs)
    }
}
