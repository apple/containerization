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

import PackageDescription

let scVersion = "0.13.0"

let package = Package(
    name: "ctr-example",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "ctr-example",
            targets: ["ctr-example"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion))
    ],
    targets: [
        .executableTarget(
            name: "ctr-example",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        )
    ]
)
