//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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
final class ImageStoreImagePullTests: ContainsAuth {
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

    @Test(.enabled(if: hasRegistryCredentials))
    func testPullImageWithoutIndex() async throws {
        let img = try await self.store.pull(reference: "ghcr.io/apple-uat/test-images/alpine-arm64:v1", auth: Self.authentication)

        let rootDescriptor = img.descriptor
        let index: ContainerizationOCI.Index = try await contentStore.get(digest: rootDescriptor.digest)!

        #expect(index.manifests.count == 1)
        let desc = index.manifests.first!
        #expect(desc.platform!.architecture == "arm64")

        await #expect(throws: Never.self) {
            let manifest: ContainerizationOCI.Manifest = try await self.contentStore.get(digest: desc.digest)!
            let _: ContainerizationOCI.Image = try await self.contentStore.get(digest: manifest.config.digest)!
            for layer in manifest.layers {
                _ = try await self.contentStore.get(digest: layer.digest)!
            }
        }
    }

    @Test(
        .enabled(if: hasRegistryCredentials),
        arguments: [
            (Platform(arch: "arm64", os: "linux", variant: "v8"), imagePullArm64Layers),
            (Platform(arch: "amd64", os: "linux"), imagePullAmd64Layers),
            (nil, imagePullTestAllLayers),
        ])
    func testPullSinglePlatform(platform: Platform?, expectLayers: [String]) async throws {
        let img = try await self.store.pull(reference: "ghcr.io/apple-uat/test-images/alpine:3.21", platform: platform, auth: Self.authentication)
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

    @Test(.enabled(if: hasRegistryCredentials))
    func testPullWithSha() async throws {
        let sha = "sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c"
        let r = "ghcr.io/apple-uat/test-images/alpine:3.21@\(sha)"
        let img = try await self.store.pull(reference: r, platform: .current, auth: Self.authentication)
        #expect(img.descriptor.digest == sha)
    }
}

let imagePullTestAllLayers = [
    "09c8ec8bf0d43a250ba7fed2eb6f242935b2987be5ed921ee06c93008558f980",
    "09de0793c07346ac2912153f6569af631291a9874dc94167d534cefc9c2d9c14",
    "11c83b29fa7f49deca4c4c597571e882adce0146997c31c99461918816e4c420",
    "159d7ed29e1fd01cbe33ccbfda619dfa93ff08349d2841e422b7c9e2d522c645",
    "184b14480d317057da092a0994ad6baf4b2df588108f43969f8fd56f021af2c6",
    "1960ae9fcc9fba89375bec92e8cbed41d5e4fab7e376ccad186084bbabf9db82",
    "1bb6442072bc5b25e4cefeaab9aecb82267e5d7dbac412be934c416e68576534",
    "1c4eef651f65e2f7daee7ee785882ac164b02b78fb74503052a26dc061c90474",
    "1de5eb4a9a6735adb46b2c9c88674c0cfba3444dd4ac2341b3babf1261700529",
    "2436f2b3b7d2537f4c5b622d7a820f00aaea1b6bd14c898142472947d5f02abe",
    "2dbd13a29595c6492a46119969dcda7d2ac35daef926e45ab62c02adb12b5173",
    "43c891410a7570c3f4ed3c1651b5e1aadd530c2d9bbc9c301ee4cb25c27d8d2f",
    "45f2dc24282db1bb78967201087c1c0699411c580555a98d20107c26e0d915e5",
    "491b6373df29cf24cfa36697aa6dd77baf5055cc7de7b7190fb07739836b2bb5",
    "51dd5201df48b2831f5894c4a9f615aaba37c5dfed453a0335018807d4b390bf",
    "5d2b0d8b1d1edede60a8e220f7b2f496b3e5341e939cf9f6d097ac1756066327",
    "64cf7d2b5187c0a2d7cb5c7216edf3e6a691753b99f92f1c0d705799ab7df452",
    "69aa61ccf55e5bf8e7a069b89e8afb42b4f3443b3785868795af8046d810d608",
    "6e771e15690e2fabf2332d3a3b744495411d6e0b00b2aea64419b58b0066cf81",
    "757d680068d77be46fd1ea20fb21db16f150468c5e7079a08a2e4705aec096ac",
    "76099982f06682e28a60c3b774ef20931d07b0a2f551203484e633d8c0361ee7",
    "7df33f7ad8beb367ac09bdd1b2f220db3ee2bbdda14a6310d1340e5628b5ba88",
    "85f3b18f9f5a8655db86c6dfb02bb01011ffef63d10a173843c5c65c3e9137b7",
    "8aa577c360a5f9b9dc36fddeace36e6c67f778d234b7fb8e8c9054a896d9ed66",
    "8d591b0b7dea080ea3be9e12ae563eebf9869168ffced1cb25b2470a3d9fe15e",
    "903bfe2ae9942c3e1520ef3b4085d3ed0ae7aa04d5b084a6b5f20c3a2bf54d37",
    "92f735dd3e28788117021933ebab6e96ebdcce599d4afa971f178e23d79c2756",
    "961e545c33866e778e904903540013b883da6d04e64ea40008ec6e0da9744d00",
    "9c2d245b3c01c4d7da0d3319d278e7aa4dd899076721abd205b595b2d3b2383b",
    "9ed449c437bfd0ca00973dbbc086fa310e8f7747d5ce78596ceeea177fdd61c8",
    "9ed53fd3b83120f78b33685d930ce9bf5aa481f6e2d165c42cbbddbeaa196f6f",
    "9fcbb9b67bffff680327c37206091da5606ca6e275adb6cfb676a3dde51255ef",
    "a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c",
    "aded1e1a5b3705116fa0a92ba074a5e0b0031647d9c315983ccba2ee5428ec8b",
    "ae871ff1c416b2496ea95b81b00ae446468c9cca84760a9c3fc29282268cec29",
    "af368b80f6520eb3f1ea2686e4afd01ee6b827b232120e18c1d37ae13034985d",
    "b5a8664a8878e813029c3f3601ba22443c4b8b4fdf18b0e7ef427103292a034a",
    "c1a599607158512214777614f916f8193d29fd34b656d47dfc26314af01e2af4",
    "c646c0556ac0609f784a201a810cc351dd3fd288e19cdd122f7c0674b207278a",
    "c6ea79a5a9bfa5cfc32d338e81b456ccf9d96498ce6868fd15818fc8a2406221",
    "cf2b3ffa5b1c87b26944dfe2005c7b9866ab5f3a91867e741e3a2e9a6f8c4152",
    "cfc6f569b62a275453b0be6e36b09ffb5cccb3c692a1189ef9d046f9b354f40a",
    "d0ec9a4a1b9b94293da606179cebe161abdecc29878e1fe9746b57c2a513c1c3",
    "d16ce3c92d1f6191fe367beac3a22940c5fab48ebb4eed5d17a63db4e9afc3f0",
    "d206c2e81af4647ceee34c716e73733e7eb60818b3ead7da067bc0825c50378c",
    "d3219e1bef3a6bdf3fe0ee09abb1402a119b4ae596e287e876fce2efa9e777c7",
    "d50b00ed88df2fd2cf92e5a9277529612d5b82156786c720efa2b13a638c8da6",
    "d524c610e0d70e2c437be31245bad77dacc2584f5cdcbdee5e059b6e6a90ad87",
    "db0ed8d0d16f8c62e6bb16440fb51de09b312c97998090fc5d13319bd7255920",
    "e219d195bcda8c6cc772c55b0a253356f1474d07b747dfeaf236b720bafcde50",
    "f18232174bc91741fdf3da96d85011092101a032a93a388b79e99e69c2d5c870",
    "f2e784527661153e36bcd9ec666145b92690614eb3ec0e78275c463de118aeba",
    "f5fb419236878e25e11358970412e1aa64413c412398739d747e1333d3e1f6d1",
    "f9e950c3f91815fdba813dad362a3b4e508b964c9128817737b6bbde89c7ed31",
    "fe0dcdd1f78341a54b6d08d0f45d91ae93eb212667d970ad15213a3168c410ee",
    "fea1779822bb485f4f88c7736e39baf15e981e3423e7583af4852db45e3c04bb",
]

let imagePullArm64Layers = [
    "6e771e15690e2fabf2332d3a3b744495411d6e0b00b2aea64419b58b0066cf81",
    "757d680068d77be46fd1ea20fb21db16f150468c5e7079a08a2e4705aec096ac",
    "8d591b0b7dea080ea3be9e12ae563eebf9869168ffced1cb25b2470a3d9fe15e",
    "a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c",
]

let imagePullAmd64Layers = [
    "1c4eef651f65e2f7daee7ee785882ac164b02b78fb74503052a26dc061c90474",
    "a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c",
    "aded1e1a5b3705116fa0a92ba074a5e0b0031647d9c315983ccba2ee5428ec8b",
    "f18232174bc91741fdf3da96d85011092101a032a93a388b79e99e69c2d5c870",
]
