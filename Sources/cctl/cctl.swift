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
import ContainerizationOCI
import Foundation
import Logging

let log = {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    var log = Logger(label: "com.apple.containerization")
    log.logLevel = .debug
    return log
}()

@main
struct Application: AsyncParsableCommand {
    static let keychainID = "com.apple.containerization"
    static let appRoot: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.containerization")
    }()

    private static let _contentStore: ContentStore = {
        try! LocalContentStore(path: appRoot.appendingPathComponent("content"))
    }()

    private static let _imageStore: ImageStore = {
        try! ImageStore(
            path: appRoot,
            contentStore: contentStore
        )
    }()

    static var imageStore: ImageStore {
        _imageStore
    }

    static var contentStore: ContentStore {
        _contentStore
    }

    static let configuration = CommandConfiguration(
        commandName: "cctl",
        abstract: "Utility CLI for Containerization",
        version: "2.0.0",
        subcommands: [
            Images.self,
            Login.self,
            Rootfs.self,
            Run.self,
        ]
    )
}

extension String {
    var absoluteURL: URL {
        URL(fileURLWithPath: self).absoluteURL
    }
}

extension String: Swift.Error {

}
