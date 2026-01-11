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

import PackageDescription

let package = Package(
    name: "swift-vminitd",
    platforms: [.macOS("15")],
    products: [
        .executable(name: "vminitd", targets: ["vminitd"]),
        .executable(name: "vmexec", targets: ["vmexec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(name: "containerization", path: "../"),
    ],
    targets: [
        .target(
            name: "LCShim"
        ),
        .target(
            name: "Cgroup",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        ),
        .executableTarget(
            name: "vminitd",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationNetlink", package: "containerization"),
                .product(name: "ContainerizationIO", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "LCShim",
                "Cgroup",
            ]
        ),
        .executableTarget(
            name: "vmexec",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "LCShim",
                "Cgroup",
            ]
        ),
    ]
)
