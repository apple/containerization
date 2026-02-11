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

struct Ext4UnpackerTests {
    // alpine image
    let indexSHA: String = "ad59e9f71edceca7b1ac7c642410858489b743c97233b0a26a5e2098b1443762"
    let fsPath = FilePath(
        FileManager.default.uniqueTemporaryDirectory()
            .appendingPathComponent("ext4.unpacked.oci.img.delme", isDirectory: false))

    final class MockEXT4Unpacker {
        static func Unpack(index: String, fsPath: FilePath) throws {
            let fs = try EXT4.Formatter(fsPath)
            let bundle = Bundle.module
            guard let indexPath = bundle.url(forResource: index, withExtension: nil) else {
                throw NSError(domain: "indexPath not found", code: 1)
            }
            let indexData = try Data(contentsOf: indexPath)
            guard let indexDict = try JSONSerialization.jsonObject(with: indexData, options: []) as? [String: Any]
            else {
                throw NSError(domain: "indexDict could not be loaded as json", code: 1)
            }
            guard let manifests = indexDict["manifests"] as? [[String: Any]] else {
                throw NSError(domain: "manifests field in index not found", code: 1)
            }
            guard let digest = manifests[0]["digest"] as? String else {
                throw NSError(domain: "digest field not found in index", code: 1)
            }
            guard
                let manifestPath = bundle.url(
                    forResource: String(digest.dropFirst("sha256:".count)), withExtension: nil)
            else {
                throw NSError(domain: "manifestPath not found", code: 1)
            }
            let manifestData = try Data(contentsOf: manifestPath)
            guard let manifestDict = try JSONSerialization.jsonObject(with: manifestData, options: []) as? [String: Any]
            else {
                throw NSError(domain: "manifestDict could not be loaded as json", code: 1)
            }
            guard let layers = manifestDict["layers"] as? [[String: Any]] else {
                throw NSError(domain: "layers field in manifests not found", code: 1)
            }
            for layer in layers {
                guard let layerDigestWithSHA = layer["digest"] as? String else {
                    throw NSError(domain: "digest field not found in layer", code: 1)
                }
                let layerDigest = String(layerDigestWithSHA.dropFirst("sha256:".count))
                guard let layerPath = bundle.url(forResource: layerDigest, withExtension: nil) else {
                    throw NSError(domain: "layer \(layerDigest) not found", code: 1)
                }
                try fs.unpack(source: layerPath)
            }
            try fs.close()
        }
    }

    @Test func eXT4Unpacker() throws {
        try MockEXT4Unpacker.Unpack(index: self.indexSHA, fsPath: self.fsPath)
        let ext4 = try EXT4.EXT4Reader(blockDevice: self.fsPath)
        let children = try ext4.children(of: EXT4.RootInode)
        #expect(
            Set(children.map { $0.0 })
                == Set([
                    ".",
                    "..",
                    "media",
                    "var",
                    "opt",
                    "lost+found",
                    "tmp",
                    "mnt",
                    "sys",
                    "usr",
                    "srv",
                    "root",
                    "etc",
                    "dev",
                    "proc",
                    "run",
                    "home",
                    "bin",
                    "lib",
                    "sbin",
                ]))
    }
}
