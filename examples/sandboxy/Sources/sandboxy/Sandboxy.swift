//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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
    var log = Logger(label: "com.apple.containerization.sandboxy")
    log.logLevel = .info
    return log
}()

@main
struct Sandboxy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandboxy",
        abstract: "Run sandboxed AI coding agents in a lightweight virtual machine",
        version: "0.1.0",
        subcommands: [
            Run.self,
            Edit.self,
            List.self,
            Remove.self,
            Cache.self,
            Config.self,
        ]
    )

    static let defaultAppRoot: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.containerization.sandboxy")
    }()

    /// Runtime data directory. Defaults to Application Support, but can be
    /// overridden via `dataDir` in `~/.config/sandboxy/config.json`.
    /// Set once during `loadConfig()` before any concurrent access.
    nonisolated(unsafe) static var appRoot: URL = defaultAppRoot

    /// Loads the config and applies `dataDir` to `appRoot` if set.
    /// Must be called before accessing `imageStore` or `contentStore`.
    static func loadConfig() throws -> SandboxyConfig {
        let fm = FileManager.default
        let agentsDir = configRoot.appendingPathComponent("agents")
        try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let config = try SandboxyConfig.load(configRoot: configRoot)
        if let dataDir = config.dataDir {
            appRoot = URL(fileURLWithPath: dataDir)
        }

        try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        return config
    }

    /// User configuration directory (`~/.config/sandboxy/`).
    /// Holds `config.json` and `agents/` definition files.
    static let configRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sandboxy")
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
}
