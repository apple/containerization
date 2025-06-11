//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIOCore

let log = {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    var log = Logger(label: "com.apple.containerization")
    log.logLevel = .debug
    return log
}()

enum IntegrationError: Swift.Error {
    case assert(msg: String)
    case noOutput
}

struct SkipTest: Swift.Error, CustomStringConvertible {
    let reason: String

    var description: String {
        reason
    }
}

@main
struct IntegrationSuite: AsyncParsableCommand {
    static let appRoot: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.containerization")
    }()

    private static let _contentStore: ContentStore = {
        try! LocalContentStore(path: appRoot.appending(path: "content"))
    }()

    private static var authentication: Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["REGISTRY_TOKEN"],
            let username = env["REGISTRY_USERNAME"]
        else {
            return nil
        }
        return BasicAuthentication(username: username, password: password)
    }

    private static let _imageStore: ImageStore = {
        try! ImageStore(
            path: appRoot,
            contentStore: contentStore
        )
    }()

    static let _testDir: URL = {
        FileManager.default.uniqueTemporaryDirectory(create: true)
    }()

    static var testDir: URL {
        _testDir
    }

    static var imageStore: ImageStore {
        _imageStore
    }

    static var contentStore: ContentStore {
        _contentStore
    }

    static let initImage = "vminit:latest"

    @Option(name: .shortAndLong, help: "Path to a log file")
    var bootlog: String

    @Option(name: .shortAndLong, help: "Path to a kernel binary")
    var kernel: String = "./bin/vmlinux"

    static func binPath(name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("bin")
            .appendingPathComponent(name)
    }

    func bootstrap() async throws -> (rootfs: Containerization.Mount, vmm: VirtualMachineManager) {
        let reference = "ghcr.io/linuxcontainers/alpine:3.20"
        let store = Self.imageStore

        let initImage = try await store.getInitImage(reference: Self.initImage)
        let initfs = try await {
            let p = Self.binPath(name: "init.block")
            do {
                return try await initImage.initBlock(at: p, for: .linuxArm)
            } catch let err as ContainerizationError {
                guard err.code == .exists else {
                    throw err
                }
                return .block(
                    format: "ext4",
                    source: p.absolutePath(),
                    destination: "/",
                    options: ["ro"]
                )
            }
        }()

        var testKernel = Kernel(path: .init(filePath: kernel), platform: .linuxArm)
        testKernel.commandLine.addDebug()
        let image = try await Self.fetchImage(reference: reference, store: store)
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

        let fs: Containerization.Mount = try await {
            let fsPath = Self.testDir.appending(component: "rootfs.ext4")
            do {
                return try await image.unpack(for: platform, at: fsPath)
            } catch let err as ContainerizationError {
                if err.code == .exists {
                    return .block(
                        format: "ext4",
                        source: fsPath.absolutePath(),
                        destination: "/",
                        options: []
                    )
                }
                throw err
            }
        }()

        let clPath = Self.testDir.appending(component: "rn.ext4").absolutePath()
        try? FileManager.default.removeItem(atPath: clPath)

        let cl = try fs.clone(to: clPath)
        return (
            cl,
            VZVirtualMachineManager(
                kernel: testKernel,
                initialFilesystem: initfs,
                bootlog: bootlog
            )
        )
    }

    static func fetchImage(reference: String, store: ImageStore) async throws -> Containerization.Image {
        do {
            return try await store.get(reference: reference)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return try await store.pull(reference: reference, auth: Self.authentication)
            }
            throw error
        }
    }

    static func adjustLimits() throws {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        limits.rlim_cur = 65536
        limits.rlim_max = 65536

        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    // Why does this exist?
    //
    // We need the virtualization entitlement to execute these tests.
    // There currently does not exist a strightforward way to do this
    // in a pure swift package.
    //
    // In order to not have a dependency on xcode, we create an executable
    // for our integration tests that can be signed then ran.
    //
    // We also can't import Testing as it expects to be run from a runner.
    // Hopefully this improves over time.
    func run() async throws {
        try Self.adjustLimits()
        let suiteStarted = CFAbsoluteTimeGetCurrent()
        log.info("starting integration suite\n")

        let tests: [String: () async throws -> Void] = [
            "process true": testProcessTrue,
            "process false": testProcessFalse,
            "process echo hi": testProcessEchoHi,
            "process user": testProcessUser,
            "multiple concurrent processes": testMultipleConcurrentProcesses,
            "multiple concurrent processes with output": testMultipleConcurrentProcessesOutput,
            "container hostname": testHostname,
            "container mount": testMounts,
            "nested virt": testNestedVirtualizationEnabled,
        ]

        var passed = 0
        var skipped = 0
        for (name, test) in tests {
            do {
                log.info("test \(name) started...")

                let started = CFAbsoluteTimeGetCurrent()
                try await test()
                let lasted = CFAbsoluteTimeGetCurrent() - started
                log.info("✅ test \(name) complete in \(lasted)s.")
                passed += 1
            } catch let err as SkipTest {
                log.info("⏭️ skipped test: \(err)")
                skipped += 1
            } catch {
                log.error("❌ test \(name) failed: \(error)")
            }
        }

        let ended = CFAbsoluteTimeGetCurrent() - suiteStarted
        var finishingText = "\n\nIntegration suite completed in \(ended)s with \(passed)/\(tests.count) passed"
        if skipped > 0 {
            finishingText += " and \(skipped)/\(tests.count) skipped"
        }
        finishingText += "!"

        log.info("\(finishingText)")

        if passed + skipped < tests.count {
            log.error("❌")
            throw ExitCode(1)
        }
        try? FileManager.default.removeItem(at: Self.testDir)
    }
}
