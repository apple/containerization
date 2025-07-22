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

//

import Testing

@testable import ContainerizationOCI

struct OCIPlatformTests {
    @Test func identicalPlatforms() {
        let amd64lhs = OCIPlatform(arch: "amd64", os: "linux")
        let amd64rhs = OCIPlatform(arch: "amd64", os: "linux")
        #expect(amd64lhs == amd64rhs, "amd64 platforms should be equal")

        let arm64lhs = OCIPlatform(arch: "arm64", os: "linux")
        let arm64rhs = OCIPlatform(arch: "arm64", os: "linux")
        #expect(arm64lhs == arm64rhs, "arm64 platforms should be equal")
    }

    @Test func differentOS() {
        let lhs = OCIPlatform(arch: "arm64", os: "linux")
        let rhs = OCIPlatform(arch: "arm64", os: "darwin")
        #expect(lhs != rhs, "Different OS should not be equal")
    }

    @Test func differentArch() {
        let lhs = OCIPlatform(arch: "amd64", os: "linux")
        let rhs = OCIPlatform(arch: "arm64", os: "linux")
        #expect(lhs != rhs, "Different arch should not be equal")
    }

    @Test func arm64_sameVariant() {
        let lhs = OCIPlatform(arch: "arm64", os: "linux", variant: "v8")
        let rhs = OCIPlatform(arch: "arm64", os: "linux", variant: "v8")
        #expect(lhs == rhs, "Both OS arm64, same arch, same variant => equal")
    }

    @Test func arm64_nilAndV8() {
        let lhs = OCIPlatform(arch: "arm64", os: "linux", variant: nil)
        let rhs = OCIPlatform(arch: "arm64", os: "linux", variant: "v8")
        #expect(lhs == rhs, "One variant nil and other v8 => equal under special arm64 rule")
    }

    @Test func arm64_nilAndV7() {
        let lhs = OCIPlatform(arch: "arm64", os: "linux", variant: nil)
        let rhs = OCIPlatform(arch: "arm64", os: "linux", variant: "v7")
        #expect(lhs != rhs, "nil vs v7 is not covered by the special rule => not equal")
    }

    @Test func arm64_bothNil() {
        let lhs = OCIPlatform(arch: "arm64", os: "linux", variant: nil)
        let rhs = OCIPlatform(arch: "arm64", os: "linux", variant: nil)
        #expect(lhs == rhs, "Both nil variants => variantEqual is true => overall equal")
    }
}
