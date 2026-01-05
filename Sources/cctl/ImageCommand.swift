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

import ArgumentParser
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension Application {
    struct Images: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "images",
            abstract: "Manage images",
            subcommands: [
                Get.self,
                Delete.self,
                Pull.self,
                Tag.self,
                Push.self,
                Save.self,
                Load.self,
            ]
        )

        func run() async throws {
            let store = Application.imageStore
            let images = try await store.list()

            print("REFERENCE\tMEDIA TYPE\tDIGEST")
            for image in images {
                print("\(image.reference)\t\(image.mediaType)\t\(image.digest)")
            }
        }

        struct Delete: AsyncParsableCommand {
            @Argument var reference: String

            func run() async throws {
                let store = Application.imageStore
                try await store.delete(reference: reference)
            }
        }

        struct Tag: AsyncParsableCommand {
            @Argument var old: String
            @Argument var new: String

            func run() async throws {
                let store = Application.imageStore
                _ = try await store.tag(existing: old, new: new)
            }
        }

        struct Get: AsyncParsableCommand {
            @Argument var reference: String

            func run() async throws {
                let store = Application.imageStore
                let image = try await store.get(reference: reference)

                let index = try await image.index()

                let enc = JSONEncoder()
                enc.outputFormatting = .prettyPrinted
                let data = try enc.encode(ImageDisplay(reference: image.reference, index: index))
                print(String(data: data, encoding: .utf8)!)
            }
        }

        struct ImageDisplay: Codable {
            let reference: String
            let index: Index
        }

        struct Pull: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "pull",
                abstract: "Pull an image's contents into a content store"
            )

            @Argument var ref: String

            @Option(name: .customLong("platform"), help: "Platform string in the form 'os/arch/variant'. Example 'linux/arm64/v8', 'linux/amd64'") var platformString: String?

            @Option(
                name: .customLong("unpack-path"), help: "Path to a new directory to unpack the image into",
                transform: { str in
                    URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
                })
            var unpackPath: String?

            @Flag(help: "Pull via plain text http") var http: Bool = false

            func run() async throws {
                let imageStore = Application.imageStore
                let platform: Platform? = try {
                    if let platformString {
                        return try Platform(from: platformString)
                    }
                    return nil
                }()

                let reference = try Reference.parse(ref)
                reference.normalize()
                let normalizedReference = reference.description
                if normalizedReference != ref {
                    print("Reference resolved to \(reference.description)")
                }

                var startTime = ContinuousClock.now
                let image = try await Images.withAuthentication(ref: normalizedReference) { auth in
                    try await imageStore.pull(reference: normalizedReference, platform: platform, insecure: http, auth: auth)
                }

                guard let image else {
                    print("image pull failed")
                    Application.exit(withError: POSIXError(.EACCES))
                }

                var duration = ContinuousClock.now - startTime
                print("Image pull took: \(duration)\n")

                guard let unpackPath else {
                    return
                }
                guard !FileManager.default.fileExists(atPath: unpackPath) else {
                    throw ContainerizationError(.exists, message: "directory already exists at \(unpackPath)")
                }
                let unpackUrl = URL(filePath: unpackPath)
                try FileManager.default.createDirectory(at: unpackUrl, withIntermediateDirectories: true)

                let unpacker = EXT4Unpacker.init(blockSizeInBytes: 2.gib())

                startTime = ContinuousClock.now
                if let platform {
                    let name = platform.description.replacingOccurrences(of: "/", with: "-")
                    let _ = try await unpacker.unpack(image, for: platform, at: unpackUrl.appending(component: name))
                } else {
                    for descriptor in try await image.index().manifests {
                        if let referenceType = descriptor.annotations?["vnd.docker.reference.type"], referenceType == "attestation-manifest" {
                            continue
                        }
                        guard let descPlatform = descriptor.platform else {
                            continue
                        }
                        let name = descPlatform.description.replacingOccurrences(of: "/", with: "-")
                        let _ = try await unpacker.unpack(image, for: descPlatform, at: unpackUrl.appending(component: name))
                        print("created snapshot for platform \(descPlatform.description)")
                    }
                }
                duration = ContinuousClock.now - startTime
                print("\nUnpacking took: \(duration)")
            }
        }

        struct Push: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "push",
                abstract: "Push an image to a remote registry"
            )

            @Option(help: "Platform string in the form 'os/arch/variant'. Example 'linux/arm64/v8', 'linux/amd64'") var platformString: String?

            @Flag(help: "Push via plain text http") var http: Bool = false

            @Argument var ref: String

            func run() async throws {
                let imageStore = Application.imageStore
                let platform: Platform? = try {
                    if let platformString {
                        return try Platform(from: platformString)
                    }
                    return nil
                }()

                let reference = try Reference.parse(ref)
                reference.normalize()
                let normalizedReference = reference.description
                if normalizedReference != ref {
                    print("Reference resolved to \(reference.description)")
                }

                try await Images.withAuthentication(ref: normalizedReference) { auth in
                    try await imageStore.push(reference: normalizedReference, platform: platform, insecure: http, auth: auth)
                }
                print("image pushed")
            }
        }

        struct Save: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "save",
                abstract: "Save one or more images to a tar archive"
            )

            @Option(help: "Platform string in the form 'os/arch/variant'. Example 'linux/arm64/v8', 'linux/amd64'") var platform: String?

            @Option(name: .shortAndLong, help: "Path to tar archive")
            var output: String

            @Argument var reference: [String]

            func run() async throws {
                var p: Platform? = nil
                if let platform {
                    p = try Platform(from: platform)
                }
                let store = Application.imageStore
                let tempDir = FileManager.default.uniqueTemporaryDirectory()
                defer {
                    try? FileManager.default.removeItem(at: tempDir)
                }
                try await store.save(references: reference, out: tempDir, platform: p)
                let writer = try ArchiveWriter(format: .pax, filter: .none, file: URL(filePath: output))
                try writer.archiveDirectory(tempDir)
                try writer.finishEncoding()
                print("image exported")
            }
        }

        struct Load: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "load",
                abstract: "Load one or more images from a tar archive"
            )

            @Option(name: .shortAndLong, help: "Path to tar archive")
            var input: String

            func run() async throws {
                let store = Application.imageStore
                let tarFile = URL(fileURLWithPath: input)
                let reader = try ArchiveReader(file: tarFile.absoluteURL)
                let tempDir = FileManager.default.uniqueTemporaryDirectory()
                defer {
                    try? FileManager.default.removeItem(at: tempDir)
                }
                try reader.extractContents(to: tempDir)
                let imported = try await store.load(from: tempDir)
                for image in imported {
                    print("imported \(image.reference)")
                }
            }
        }

        private static func withAuthentication<T>(
            ref: String, _ body: @Sendable @escaping (_ auth: Authentication?) async throws -> T?
        ) async throws -> T? {
            var authentication: Authentication?
            let ref = try Reference.parse(ref)
            guard let host = ref.resolvedDomain else {
                throw ContainerizationError(.invalidArgument, message: "no host specified in image reference")
            }
            authentication = Self.authenticationFromEnv(host: host)
            if let authentication {
                return try await body(authentication)
            }
            let keychain = KeychainHelper(id: Application.keychainID)
            authentication = try? keychain.lookup(domain: host)
            return try await body(authentication)
        }

        private static func authenticationFromEnv(host: String) -> Authentication? {
            let env = ProcessInfo.processInfo.environment
            guard env["REGISTRY_HOST"] == host else {
                return nil
            }
            guard let user = env["REGISTRY_USERNAME"], let password = env["REGISTRY_TOKEN"] else {
                return nil
            }
            return BasicAuthentication(username: user, password: password)
        }
    }
}
