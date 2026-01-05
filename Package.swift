// swift-tools-version: 6.2
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

// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import Foundation
import PackageDescription

let package = Package(
    name: "containerization",
    platforms: [.macOS("15")],
    products: [
        .library(name: "Containerization", targets: ["Containerization", "ContainerizationError"]),
        .library(name: "ContainerizationEXT4", targets: ["ContainerizationEXT4"]),
        .library(name: "ContainerizationOCI", targets: ["ContainerizationOCI"]),
        .library(name: "ContainerizationNetlink", targets: ["ContainerizationNetlink"]),
        .library(name: "ContainerizationIO", targets: ["ContainerizationIO"]),
        .library(name: "ContainerizationOS", targets: ["ContainerizationOS"]),
        .library(name: "ContainerizationExtras", targets: ["ContainerizationExtras"]),
        .library(name: "ContainerizationArchive", targets: ["ContainerizationArchive"]),
        .executable(name: "cctl", targets: ["cctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.26.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.36.0"),
    ],
    targets: [
        .target(
            name: "ContainerizationError"
        ),
        .target(
            name: "Containerization",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                "ContainerizationOCI",
                "ContainerizationOS",
                "ContainerizationIO",
                "ContainerizationExtras",
                .target(name: "ContainerizationEXT4", condition: .when(platforms: [.macOS])),
            ],
            exclude: [
                "../Containerization/SandboxContext/SandboxContext.proto"
            ]
        ),
        .executableTarget(
            name: "cctl",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "Containerization",
                "ContainerizationOS",
            ]
        ),
        .executableTarget(
            name: "containerization-integration",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "Containerization",
            ],
            path: "Sources/Integration"
        ),
        .testTarget(
            name: "ContainerizationUnitTests",
            dependencies: ["Containerization"],
            path: "Tests/ContainerizationTests",
            resources: [
                .copy("ImageTests/Resources/scratch.tar"),
                .copy("ImageTests/Resources/scratch_no_annotations.tar"),
            ]
        ),
        .target(
            name: "ContainerizationEXT4",
            dependencies: [
                .target(name: "ContainerizationArchive", condition: .when(platforms: [.macOS])),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerizationOS",
            ],
            path: "Sources/ContainerizationEXT4",
            exclude: [
                "README.md"
            ]
        ),
        .testTarget(
            name: "ContainerizationEXT4Tests",
            dependencies: [
                "ContainerizationEXT4",
                "ContainerizationArchive",
            ],
            resources: [
                .copy(
                    "Resources/content/blobs/sha256/ad59e9f71edceca7b1ac7c642410858489b743c97233b0a26a5e2098b1443762"),  // index
                .copy(
                    "Resources/content/blobs/sha256/48a06049d3738991b011ca8b12473d712b7c40666a1462118dae3c403676afc2"),  // manifest
                .copy(
                    "Resources/content/blobs/sha256/8e2eb240a6cd7be1a0d308125afe0060b020e89275ced2e729eda7d4eeff62a2"),  // config
                .copy(
                    "Resources/content/blobs/sha256/c6b39de5b33961661dc939b997cc1d30cda01e38005a6c6625fd9c7e748bab44"),  // layer 1
                .copy(
                    "Resources/content/blobs/sha256/4f4fb700ef54461cfa02571ae0db9a0dc1e0cdb5577484a6d75e68dc38e8acc1"),  // layer 2
            ]
        ),
        .target(
            name: "ContainerizationArchive",
            dependencies: [
                "CArchive",
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerizationExtras",
            ],
            exclude: [
                "CArchive"
            ]
        ),
        .testTarget(
            name: "ContainerizationArchiveTests",
            dependencies: [
                "ContainerizationArchive"
            ]
        ),
        .target(
            name: "CArchive",
            dependencies: [],
            path: "Sources/ContainerizationArchive/CArchive",
            cSettings: [
                .define(
                    "PLATFORM_CONFIG_H", to: "\"config_darwin.h\"",
                    .when(platforms: [.iOS, .macOS, .macCatalyst, .watchOS, .driverKit, .tvOS])),
                .define("PLATFORM_CONFIG_H", to: "\"config_linux.h\"", .when(platforms: [.linux])),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("lzma"),
                .linkedLibrary("archive"),
                .linkedLibrary("iconv", .when(platforms: [.macOS])),
                .linkedLibrary("crypto", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "ContainerizationOCI",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                "ContainerizationError",
                "ContainerizationOS",
                "ContainerizationExtras",
            ]
        ),
        .testTarget(
            name: "ContainerizationOCITests",
            dependencies: [
                "ContainerizationOCI",
                "Containerization",
                "ContainerizationIO",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "ContainerizationNetlink",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "ContainerizationOS",
                "ContainerizationExtras",
            ]
        ),
        .testTarget(
            name: "ContainerizationNetlinkTests",
            dependencies: [
                "ContainerizationNetlink"
            ]
        ),
        .target(
            name: "ContainerizationOS",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "CShim",
                "ContainerizationError",
            ],
            exclude: [
                "../ContainerizationOS/README.md"
            ]
        ),
        .testTarget(
            name: "ContainerizationOSTests",
            dependencies: [
                "ContainerizationOS",
                "ContainerizationExtras",
            ]
        ),
        .target(
            name: "ContainerizationIO",
            dependencies: [
                "ContainerizationOS",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .target(
            name: "ContainerizationExtras",
            dependencies: [
                "ContainerizationError",
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),

            ]
        ),
        .testTarget(
            name: "ContainerizationExtrasTests",
            dependencies: [
                "ContainerizationExtras",
                "CShim",
            ]
        ),
        .target(
            name: "CShim"
        ),
    ]
)
