//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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
import ContainerizationOS
import Foundation
import Logging
import NIOCore
import NIOPosix

#if os(Linux)
import Musl
import LCShim
#else
import Darwin
#endif

@main
struct Application: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vminitd",
        abstract: "VM init process and container agent",
        version: "1.0.0",
        subcommands: [
            InitCommand.self,
            FsNotifyCommand.self,
        ],
        defaultSubcommand: InitCommand.self
    )

    static let foregroundEnvVar = "FOREGROUND"
    static let vsockPort = 1024
    static let standardErrorLock = NSLock()

    static func runInForeground(_ log: Logger) throws {
        precondition(getpid() != 1, "runInForeground must not be called as PID 1")
        log.info("running vminitd under pid1 wrapper")

        var command = Command("/sbin/vminitd")
        command.attrs = .init(setsid: true)
        command.stdin = .standardInput
        command.stdout = .standardOutput
        command.stderr = .standardError

        var env = ProcessInfo.processInfo.environment
        env[foregroundEnvVar] = "1"
        command.environment = env.map { "\($0.key)=\($0.value)" }

        try command.start()
        _ = try command.wait()
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

    @Sendable
    static func standardError(label: String) -> StreamLogHandler {
        standardErrorLock.withLock {
            StreamLogHandler.standardError(label: label)
        }
    }

    static func exit(_ code: Int32) -> Never {
        #if os(Linux)
        Musl.exit(code)
        #else
        Darwin.exit(code)
        #endif
    }
}

extension Application {
    struct InitCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Run vminitd as init process (default)"
        )

        func run() async throws {
            LoggingSystem.bootstrap(Application.standardError)
            var log = Logger(label: "vminitd")

            try Application.adjustLimits()

            // when running under debug mode, launch vminitd as a sub process of pid1
            // so that we get a chance to collect better logs and errors before pid1 exists
            // and the kernel panics.
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            let foreground = environment[Application.foregroundEnvVar]
            let isPid1 = (getpid() == 1)
            log.info("checking for shim var \(Application.foregroundEnvVar)=\(String(describing: foreground)); pid=\(getpid())")

            // only use the FOREGROUND shim when we're not PID 1
            // if we are PID 1 (fresh VM boot), skip the shim to avoid exiting init
            if foreground == nil && !isPid1 {
                try Application.runInForeground(log)
                Application.exit(0)  // parent is not PID 1; safe to exit after child completes
            }

            // we only need to be a subreaper when we're not PID 1
            // (when PID 1, the kernel already reaps children)
            if !isPid1 {
                CZ_set_sub_reaper()
            }
            #endif

            signal(SIGPIPE, SIG_IGN)

            // Because the sysctl rpc wouldn't make sense if this didn't always exist, we
            // ALWAYS mount /proc.
            guard Musl.mount("proc", "/proc", "proc", 0, "") == 0 else {
                log.error("failed to mount /proc")
                Application.exit(1)
            }
            guard Musl.mount("tmpfs", "/run", "tmpfs", 0, "") == 0 else {
                log.error("failed to mount /run")
                Application.exit(1)
            }
            try Binfmt.mount()

            log.logLevel = .debug

            log.info("vminitd booting")
            let eg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            let server = Initd(log: log, group: eg)

            do {
                log.info("serving vminitd API")
                try await server.serve(port: Application.vsockPort)
                log.info("vminitd API returned")
            } catch {
                log.error("vminitd boot error \(error)")
                Application.exit(1)
            }
        }
    }
}

extension Application {
    struct FsNotifyCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fs-notify",
            abstract: "Internal command to run filesystem notification worker in container namespace",
            shouldDisplay: false
        )

        @Argument(help: "Container PID whose namespace to enter")
        var containerPID: Int32

        private static let handshakeReady: UInt8 = 0xAA
        private static let handshakeFailure: UInt8 = 0xFF

        func run() throws {
            // FD 3 = socket (extraFiles[0]), FD 4 = error pipe (extraFiles[1])
            let socketFD: Int32 = 3
            let errorPipeFD: Int32 = 4

            do {
                try enterContainerNamespace(containerPID: containerPID)
                close(errorPipeFD)
            } catch {
                let errorMsg = "Failed to enter namespace: \(error)"
                _ = errorMsg.utf8CString.withUnsafeBufferPointer { buffer in
                    // -1 to skip null terminator
                    write(errorPipeFD, buffer.baseAddress, buffer.count - 1)
                }
                close(errorPipeFD)

                var failureHandshake = Self.handshakeFailure
                _ = write(socketFD, &failureHandshake, 1)
                close(socketFD)
                Application.exit(1)
            }

            var readyHandshake = Self.handshakeReady
            guard write(socketFD, &readyHandshake, 1) == 1 else {
                close(socketFD)
                Application.exit(1)
            }

            while true {
                do {
                    guard let (eventID, path, eventType) = try readEventFromParent(socket: socketFD) else {
                        break
                    }

                    var success: UInt8 = 1
                    do {
                        try generateSyntheticInotifyEvent(path: path, eventType: eventType)
                    } catch {
                        success = 0
                    }

                    try sendResponseToParent(socket: socketFD, eventID: eventID, success: success)
                } catch {
                    break
                }
            }

            close(socketFD)
        }

        private func enterContainerNamespace(containerPID: Int32) throws {
            let nsPath = "/proc/\(containerPID)/ns/mnt"
            let vmNsPath = "/proc/self/ns/mnt"

            let containerNsStatPtr = UnsafeMutablePointer<stat>.allocate(capacity: 1)
            let vmNsStatPtr = UnsafeMutablePointer<stat>.allocate(capacity: 1)
            defer {
                containerNsStatPtr.deallocate()
                vmNsStatPtr.deallocate()
            }

            let containerStatResult = stat(nsPath, containerNsStatPtr)
            let vmStatResult = stat(vmNsPath, vmNsStatPtr)

            if containerStatResult == 0 && vmStatResult == 0 {
                let containerInode = containerNsStatPtr.pointee.st_ino
                let vmInode = vmNsStatPtr.pointee.st_ino

                if containerInode == vmInode {
                    return
                }
            }

            let fd = open(nsPath, O_RDONLY)
            guard fd >= 0 else {
                throw ContainerizationError(.internalError, message: "Failed to open namespace file: \(nsPath), errno \(errno)")
            }
            defer {
                _ = close(fd)
            }
            let _ = unshare(CLONE_FS)
            let setnsResult = setns(fd, CLONE_NEWNS)
            guard setnsResult == 0 else {
                throw ContainerizationError(.internalError, message: "Failed to setns to mount namespace: errno \(errno)")
            }
        }

        private func readEventFromParent(socket: Int32) throws -> (UInt32, String, Com_Apple_Containerization_Sandbox_V3_FileSystemEventType)? {
            var eventTypeValue: UInt32 = 0
            guard read(socket, &eventTypeValue, 4) == 4 else { return nil }
            eventTypeValue = UInt32(bigEndian: eventTypeValue)

            var pathLen: UInt32 = 0
            guard read(socket, &pathLen, 4) == 4 else { return nil }
            pathLen = UInt32(bigEndian: pathLen)

            let pathData = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(pathLen))
            defer { pathData.deallocate() }
            guard read(socket, pathData, Int(pathLen)) == pathLen else { return nil }
            let pathBytes = Data(bytes: pathData, count: Int(pathLen))
            guard let path = String(data: pathBytes, encoding: .utf8) else { return nil }

            var eventID: UInt32 = 0
            guard read(socket, &eventID, 4) == 4 else { return nil }
            eventID = UInt32(bigEndian: eventID)

            guard let eventType = Com_Apple_Containerization_Sandbox_V3_FileSystemEventType(rawValue: Int(eventTypeValue)) else {
                return nil
            }

            return (eventID, path, eventType)
        }

        private func sendResponseToParent(socket: Int32, eventID: UInt32, success: UInt8) throws {
            var buffer = Data()
            buffer.append(contentsOf: withUnsafeBytes(of: eventID.bigEndian) { Data($0) })
            buffer.append(success)

            try buffer.withUnsafeBytes { bytes in
                let written = write(socket, bytes.bindMemory(to: UInt8.self).baseAddress, buffer.count)
                guard written == buffer.count else {
                    throw ContainerizationError(.internalError, message: "Failed to write response to parent")
                }
            }
        }

        private func generateSyntheticInotifyEvent(
            path: String,
            eventType: Com_Apple_Containerization_Sandbox_V3_FileSystemEventType
        ) throws {
            if eventType == .delete && !FileManager.default.fileExists(atPath: path) {
                return
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber else {
                throw ContainerizationError(.internalError, message: "Failed to get file permissions for path: \(path)")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: path
            )
        }
    }
}
