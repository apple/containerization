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

import ContainerizationOCI
import Crypto
import Foundation
import NIO
import Testing

@testable import Containerization

@Suite
final class ImageStoreImagePullTests {
    let store: ImageStore
    let dir: URL
    let contentStore: ContentStore

    public init() {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let cs = try! LocalContentStore(path: dir)
        let store = try! ImageStore(path: dir, contentStore: cs)
        self.dir = dir
        self.store = store
        self.contentStore = cs
    }

    deinit {
        try! FileManager.default.removeItem(at: self.dir)
    }

    @Test func testPullImageWithoutIndex() async throws {
        let img = try await self.store.pull(reference: "ghcr.io/apple/containerization/dockermanifestimage:0.0.2")

        let rootDescriptor = img.descriptor
        let index: ContainerizationOCI.Index = try await contentStore.get(digest: rootDescriptor.digest)!

        #expect(index.manifests.count == 1)
        let desc = index.manifests.first!
        #expect(desc.platform!.architecture == "amd64")

        await #expect(throws: Never.self) {
            let manifest: ContainerizationOCI.Manifest = try await self.contentStore.get(digest: desc.digest)!
            let _: ContainerizationOCI.Image = try await self.contentStore.get(digest: manifest.config.digest)!
            for layer in manifest.layers {
                _ = try await self.contentStore.get(digest: layer.digest)!
            }
        }
    }

    @Test(
        arguments: [
            (Platform(arch: "arm64", os: "linux", variant: "v8"), imagePullArm64Layers),
            (Platform(arch: "amd64", os: "linux"), imagePullAmd64Layers),
            (nil, imagePullTestAllLayers),
        ])
    func testPullSinglePlatform(platform: Platform?, expectLayers: [String]) async throws {
        let img = try await self.store.pull(
            reference: "ghcr.io/linuxcontainers/alpine:3.20@sha256:0a6a86d44d7f93c4f2b8dea7f0eee64e72cb98635398779f3610949632508d57", platform: platform)
        let rootDescriptor = img.descriptor
        let index: ContainerizationOCI.Index = try await contentStore.get(digest: rootDescriptor.digest)!
        var foundMatch = false
        for desc in index.manifests {
            if let platform {
                if desc.platform != platform {
                    continue
                }
            }
            foundMatch = true
            await #expect(throws: Never.self) {
                let manifest: ContainerizationOCI.Manifest = try await self.contentStore.get(digest: desc.digest)!
                let _: ContainerizationOCI.Image = try await self.contentStore.get(digest: manifest.config.digest)!
                for layer in manifest.layers {
                    _ = try await self.contentStore.get(digest: layer.digest)!
                }
            }
        }
        #expect(foundMatch)
        let contentPath = dir.appendingPathComponent("blobs/sha256")
        let filesOnDisk = try FileManager.default.contentsOfDirectory(at: contentPath, includingPropertiesForKeys: nil).map {
            $0.lastPathComponent
        }.sorted()
        #expect(filesOnDisk == expectLayers)
    }

    @Test func testPullWithSha() async throws {
        let sha = "sha256:0a6a86d44d7f93c4f2b8dea7f0eee64e72cb98635398779f3610949632508d57"
        let r = "ghcr.io/linuxcontainers/alpine:3.20@\(sha)"
        let img = try await self.store.pull(reference: r, platform: .current)
        #expect(img.descriptor.digest == sha)
    }
}

let imagePullTestAllLayers = [
    "013c522f9494ecda30dc8fbee7805b59c773573fd080c74e6835def22547bd07",
    "037316e2a3a13e6d7e15057d3ede6ad063f15c92216778576ee88a74e6f7c6fc",
    "0566dbe8e93e20dbfebc6b023399a6eb337719faf1d11dab57f975286c198a00",
    "0928a8adc0d420ddda0d25c76e95282534a5b69b13ffcbb6ddbc41c50fc77550",
    "0a6a86d44d7f93c4f2b8dea7f0eee64e72cb98635398779f3610949632508d57",
    "0a9a5dfd008f05ebc27e4790db0709a29e527690c21bcbcd01481eaeb6bb49dc",
    "0c11ea92e0d923e7812d258defbe6788642547fa347969a3dbd7bb7cbc0a9666",
    "156724324a3250a38177b0328390d7efb4ba85d7e095ad7af9ca19a3cd46f855",
    "1c2a87b1633d21ffcd8192bc84f9bed0c479bbcfbcd8b76b9ca1b8bf8bc61516",
    "2803bd9fd5a5e53bc39c576b3e7eaf4839ec77dcc1274c6ad9f7d534ccc566c7",
    "2d2e65d21b1f1a7cf14b99e54809bb4eee749fa9145d1e263279e18e246e5e1b",
    "34bac5d0022b2997fdfd5c678521d6afe58a4ea6c65d5d31e3ece0be141158ea",
    "3e6ec69548a14d7bf37b242f02f26dd41c69e9c510225078ca1f241ef249b3df",
    "423949aec9a2fe60140a59926634f90979ac19878957becf9902dcc547592a44",
    "4817c12fc96d333e818e9f56f22a7c8683bd3ca8b0c04ce45e188dc6aaf8e5c3",
    "4e32c214e82a5d6ccb62b58fb42405fc961c69da5fe02c670f1e4c62c8eb6fbb",
    "4ea6a163031004a9a61288b7a5ffbf73d84115d398abe5180caeb15442d1a5fe",
    "4f0bb7ea5efffa5762fc231a403f232ca3ea43ef6db18d4bf52aeca8c15d7dec",
    "55a8c211d2e969b7b7e9e4825853cf24a75cbbcaf7728db15840c1514838a23d",
    "5c979effb79226e255a01eaeb2a525bd12019c02eba2b76f6e0726dd2701508e",
    "63e2abc26a64dea41796995524777edc558e143bea4929f06954c52706363f33",
    "6d8b5334139bdee0462dd4d6cc85fdec98ad4d97155075973432ec4ff67906c9",
    "6f3c7dfa949497fb255d0a28c244e7add0d52ae6318b45947a8a2940d846b2e2",
    "718fbe9a22ec3da853bdbd5d8112f2dc8ba41f30d46899b3792242f16a0f8b41",
    "744d40c360fd0988b20b15ab845d3db943817b027f38ea6850361bab4ac916be",
    "76a0ff976fd7cf0f21858535989ef59ac2ee64a3f1bf1b68d98d15138cd46afa",
    "772078ddbdee5be52d429e08f953aaad6715a90d7e4d6496eb1cd4004efa8a95",
    "7c6bf3be7c8016421fb3033e19b6a313f264093e1ac9e77c9f931ade0d61b3f7",
    "7f608f0a59b5b3717cdd3cc61ef59c329d3c2c16c5fc6963b3b13360d43841c0",
    "81fc5885a3ad37110bf576934de28326e1194bd943e020bc3924502335fdf181",
    "84df3263e35ed35440625ae0ebb5b1c3d00f57ffcec61188015d5217988a8b35",
    "85b46e4c8e4841ce7964ce897a07a4d9df7d589322593fb600dd428e47d635ae",
    "872bd582507dfe35ccd496fcd128f61963620053a722b517353f3d9df46412e9",
    "8a9fb51ac81600da44afb1c4a5df4745d23eca0cc5d924f989c074f3da7a9440",
    "90bb43c8fe064682d965fe27b1ca0cf2b42cf0273914cc20a4e636e174ccdaf5",
    "9368b67dac9dc00ca8dbbd25b6f148fd6229b01dac5ff3d89281bd296cf196c6",
    "94e9d8af22013aabf0edcaf42950c88b0a1350c3a9ce076d61b98a535a673dd9",
    "9cbaf16e9229ef1466c71cf97a75ddd7d2041522012dd1bcace0d56a9ad77688",
    "9cfe406db828239417e29e2c00bdf196c32b39ffcead4c2e28cdf60ff8a8dd58",
    "adc8e49a814d3e4f73ccdd1d26d4cbd3f1a338b4e136a55c092bdcca57863225",
    "b1ca1bb0a5f203b48e1ca60861ae852f49b910ce8488c19c392a3bc7ee31b072",
    "b3d7db73e90671cb6b7925cc878d43a2781451bed256cf0626110f5386cdd4dc",
    "bfc9829f240e42bab6b756c64179b8e73317baf0e9a8940ea1571cb2f29efcc3",
    "c70d93f05189a8a6a10ba5657b8e89e849f2c7491d76587178f75d9fca228bf1",
    "c9813c0f5a2f289ea6175876fd973d6d8adcd495da4a23e9273600c8f0a761c5",
    "c9aedc9d4e47fa9429e5c329420d8a93e16c433e361d0f9281565ed4da3c057e",
    "d27e7628ef6e28a3e91cdc1ef1f998a703d356067ecedddfe9e9281e36d8c9f9",
    "ef99f4640fe11015a03439935b827bff242d0db64db27db005a31ab4497db4a2",
    "f2c7f3c3fecbf01204eccd798e2f77b0003a8567927a5d6242fd3ed81727fee9",
    "f882dda529d0cd4b586a10a7f60048c7f8faaff26d6672008d0478b8b004bc63",
]

let imagePullArm64Layers = [
    "0a6a86d44d7f93c4f2b8dea7f0eee64e72cb98635398779f3610949632508d57",
    "3e6ec69548a14d7bf37b242f02f26dd41c69e9c510225078ca1f241ef249b3df",
    "423949aec9a2fe60140a59926634f90979ac19878957becf9902dcc547592a44",
    "76a0ff976fd7cf0f21858535989ef59ac2ee64a3f1bf1b68d98d15138cd46afa",
    "94e9d8af22013aabf0edcaf42950c88b0a1350c3a9ce076d61b98a535a673dd9",
]

let imagePullAmd64Layers = [
    "0a6a86d44d7f93c4f2b8dea7f0eee64e72cb98635398779f3610949632508d57",
    "0a9a5dfd008f05ebc27e4790db0709a29e527690c21bcbcd01481eaeb6bb49dc",
    "156724324a3250a38177b0328390d7efb4ba85d7e095ad7af9ca19a3cd46f855",
    "1c2a87b1633d21ffcd8192bc84f9bed0c479bbcfbcd8b76b9ca1b8bf8bc61516",
    "4ea6a163031004a9a61288b7a5ffbf73d84115d398abe5180caeb15442d1a5fe",
]
