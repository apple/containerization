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

//

import Testing

@testable import ContainerizationOCI

struct OCIPlatformTests {
    @Test func identicalPlatforms() {
        let amd64lhs = Platform(arch: "amd64", os: "linux")
        let amd64rhs = Platform(arch: "amd64", os: "linux")
        #expect(amd64lhs == amd64rhs, "amd64 platforms should be equal")

        let arm64lhs = Platform(arch: "arm64", os: "linux")
        let arm64rhs = Platform(arch: "arm64", os: "linux")
        #expect(arm64lhs == arm64rhs, "arm64 platforms should be equal")
    }

    @Test func differentOS() {
        let lhs = Platform(arch: "arm64", os: "linux")
        let rhs = Platform(arch: "arm64", os: "darwin")
        #expect(lhs != rhs, "Different OS should not be equal")
    }

    @Test func differentArch() {
        let lhs = Platform(arch: "amd64", os: "linux")
        let rhs = Platform(arch: "arm64", os: "linux")
        #expect(lhs != rhs, "Different arch should not be equal")
    }

    @Test func arm64_sameVariant() {
        let lhs = Platform(arch: "arm64", os: "linux", variant: "v8")
        let rhs = Platform(arch: "arm64", os: "linux", variant: "v8")
        #expect(lhs == rhs, "Both OS arm64, same arch, same variant => equal")
    }

    @Test func arm64_nilAndV8() {
        let lhs = Platform(arch: "arm64", os: "linux", variant: nil)
        let rhs = Platform(arch: "arm64", os: "linux", variant: "v8")
        #expect(lhs == rhs, "One variant nil and other v8 => equal under special arm64 rule")
    }

    @Test func arm64_nilAndV7() {
        let lhs = Platform(arch: "arm64", os: "linux", variant: nil)
        let rhs = Platform(arch: "arm64", os: "linux", variant: "v7")
        #expect(lhs != rhs, "nil vs v7 is not covered by the special rule => not equal")
    }

    @Test func arm64_bothNil() {
        let lhs = Platform(arch: "arm64", os: "linux", variant: nil)
        let rhs = Platform(arch: "arm64", os: "linux", variant: nil)
        #expect(lhs == rhs, "Both nil variants => variantEqual is true => overall equal")
    }

    @Test func arm64_nilAndV8_sameHashValue() {
        let withoutVariant = Platform(arch: "arm64", os: "linux", variant: nil)
        let withV8 = Platform(arch: "arm64", os: "linux", variant: "v8")
        // Equal platforms must produce the same hash — violating this breaks Set/Dictionary lookups
        #expect(withoutVariant.hashValue == withV8.hashValue, "arm64 nil variant and v8 must hash identically")
    }

    @Test func arm64_nilAndV8_setLookup() {
        let withoutVariant = Platform(arch: "arm64", os: "linux", variant: nil)
        let withV8 = Platform(arch: "arm64", os: "linux", variant: "v8")
        var set = Set<Platform>()
        set.insert(withoutVariant)
        #expect(set.contains(withV8), "arm64/v8 must be found in a Set that contains arm64 with nil variant")
    }

    // MARK: - description consistency (issue apple/container#1542)

    @Test func arm64_nilAndV8_sameDescription() {
        let withoutVariant = Platform(arch: "arm64", os: "linux", variant: nil)
        let withV8 = Platform(arch: "arm64", os: "linux", variant: "v8")
        #expect(
            withoutVariant.description == withV8.description,
            "equal arm64 platforms must produce the same description"
        )
    }

    @Test func arm64_descriptionDropsRedundantV8() {
        let withV8 = Platform(arch: "arm64", os: "linux", variant: "v8")
        #expect(withV8.description == "linux/arm64", "arm64/v8 is canonical arm64, rendered without the redundant variant")
    }

    @Test func arm64_nilVariantDescription() {
        let withoutVariant = Platform(arch: "arm64", os: "linux", variant: nil)
        #expect(withoutVariant.description == "linux/arm64")
    }

    @Test func arm64_fromStringWithV8DescriptionIsCanonical() throws {
        let parsed = try Platform(from: "linux/arm64/v8")
        #expect(parsed.description == "linux/arm64", "parsing arm64/v8 then describing must yield the canonical short form")
    }

    @Test func arm_v7_descriptionKeepsVariant() {
        let armv7 = Platform(arch: "arm", os: "linux", variant: "v7")
        #expect(armv7.description == "linux/arm/v7", "non-redundant variants such as arm/v7 must be preserved")
    }

    @Test func amd64_descriptionUnaffected() {
        let amd64 = Platform(arch: "amd64", os: "linux")
        #expect(amd64.description == "linux/amd64")
    }
}
