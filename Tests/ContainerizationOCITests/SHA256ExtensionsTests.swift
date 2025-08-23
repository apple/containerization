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

import Crypto
import Foundation
import Testing

@testable import ContainerizationOCI

struct SHA256ExtensionsTests {

    @Test func digestStringFormat() {
        let testData = "Hello, World!".data(using: .utf8)!
        let digest = SHA256.hash(data: testData)
        let digestString = digest.digestString

        #expect(digestString.hasPrefix("sha256:"))
        #expect(digestString.count == 71)  // "sha256:" (7) + 64 hex chars

        // Verify it's properly formatted hex
        let hexPart = String(digestString.dropFirst(7))
        #expect(hexPart.count == 64)

        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        for char in hexPart {
            #expect(hexCharacterSet.contains(char.unicodeScalars.first!))
        }
    }

    @Test func encodedFormat() {
        let testData = "Hello, World!".data(using: .utf8)!
        let digest = SHA256.hash(data: testData)
        let encoded = digest.encoded

        #expect(!encoded.hasPrefix("sha256:"))
        #expect(encoded.count == 64)  // Just the hex chars

        // Verify it's properly formatted hex
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        for char in encoded {
            #expect(hexCharacterSet.contains(char.unicodeScalars.first!))
        }
    }

    @Test func digestStringAndEncodedConsistency() {
        let testData = "Test data for consistency".data(using: .utf8)!
        let digest = SHA256.hash(data: testData)

        let digestString = digest.digestString
        let encoded = digest.encoded

        // digestString should be "sha256:" + encoded
        #expect(digestString == "sha256:\(encoded)")
    }

    @Test func differentDataProducesDifferentHashes() {
        let data1 = "First test string".data(using: .utf8)!
        let data2 = "Second test string".data(using: .utf8)!

        let digest1 = SHA256.hash(data: data1)
        let digest2 = SHA256.hash(data: data2)

        #expect(digest1.digestString != digest2.digestString)
        #expect(digest1.encoded != digest2.encoded)
    }

    @Test func emptyDataHash() {
        let emptyData = Data()
        let digest = SHA256.hash(data: emptyData)

        let digestString = digest.digestString
        let encoded = digest.encoded

        #expect(digestString.hasPrefix("sha256:"))
        #expect(encoded.count == 64)
        #expect(digestString == "sha256:\(encoded)")

        // Empty data should produce known hash
        #expect(encoded == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func largeDataHash() {
        // Test with larger data
        let largeData = Data(repeating: 0x42, count: 1024 * 1024)  // 1MB of 0x42
        let digest = SHA256.hash(data: largeData)

        let digestString = digest.digestString
        let encoded = digest.encoded

        #expect(digestString.hasPrefix("sha256:"))
        #expect(encoded.count == 64)
        #expect(digestString == "sha256:\(encoded)")
    }

    @Test func unicodeDataHash() {
        let unicodeString = "Hello 世界! 🌍 Testing unicode: àáâãäåæçèéêë"
        let unicodeData = unicodeString.data(using: .utf8)!
        let digest = SHA256.hash(data: unicodeData)

        let digestString = digest.digestString
        let encoded = digest.encoded

        #expect(digestString.hasPrefix("sha256:"))
        #expect(encoded.count == 64)
        #expect(digestString == "sha256:\(encoded)")

        // Same unicode string should produce same hash
        let digest2 = SHA256.hash(data: unicodeString.data(using: .utf8)!)
        #expect(digest.encoded == digest2.encoded)
    }

    @Test func binaryDataHash() {
        // Test with binary data (not UTF-8 text)
        var binaryData = Data()
        for i in 0..<256 {
            binaryData.append(UInt8(i))
        }

        let digest = SHA256.hash(data: binaryData)
        let digestString = digest.digestString
        let encoded = digest.encoded

        #expect(digestString.hasPrefix("sha256:"))
        #expect(encoded.count == 64)
        #expect(digestString == "sha256:\(encoded)")
    }

    @Test func hashConsistency() {
        // Same data should always produce same hash
        let testData = "Consistency test data".data(using: .utf8)!

        let digest1 = SHA256.hash(data: testData)
        let digest2 = SHA256.hash(data: testData)
        let digest3 = SHA256.hash(data: testData)

        #expect(digest1.digestString == digest2.digestString)
        #expect(digest2.digestString == digest3.digestString)
        #expect(digest1.encoded == digest2.encoded)
        #expect(digest2.encoded == digest3.encoded)
    }

    @Test func knownTestVectors() {
        // Test some known SHA256 test vectors
        let testCases = [
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
        ]

        for (input, expectedHex) in testCases {
            let data = input.data(using: .utf8)!
            let digest = SHA256.hash(data: data)

            #expect(digest.encoded == expectedHex)
            #expect(digest.digestString == "sha256:\(expectedHex)")
        }
    }
}
