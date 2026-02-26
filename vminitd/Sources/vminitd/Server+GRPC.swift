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

import Cgroup
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationNetlink
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPC
import Logging
import NIOCore
import NIOPosix
import SwiftProtobuf
import SystemPackage
import _ContainerizationTar

private let _setenv = Foundation.setenv

#if canImport(Musl)
import Musl
private let _mount = Musl.mount
private let _umount = Musl.umount2
private let _kill = Musl.kill
private let _sync = Musl.sync
#elseif canImport(Glibc)
import Glibc
private let _mount = Glibc.mount
private let _umount = Glibc.umount2
private let _kill = Glibc.kill
private let _sync = Glibc.sync
#endif

extension ContainerizationError {
    func toGRPCStatus(operation: String) -> GRPCStatus {
        let message = "\(operation): \(self)"
        let code: GRPCStatus.Code = {
            switch self.code {
            case .invalidArgument:
                return .invalidArgument
            case .notFound:
                return .notFound
            case .exists:
                return .alreadyExists
            case .cancelled:
                return .cancelled
            case .unsupported:
                return .unimplemented
            case .unknown:
                return .unknown
            case .internalError:
                return .internalError
            case .interrupted:
                return .unavailable
            case .invalidState:
                return .failedPrecondition
            case .timeout:
                return .deadlineExceeded
            default:
                return .internalError
            }
        }()
        return GRPCStatus(code: code, message: message, cause: self)
    }
}

extension Initd: Com_Apple_Containerization_Sandbox_V3_SandboxContextAsyncProvider {
    func setTime(
        request: Com_Apple_Containerization_Sandbox_V3_SetTimeRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SetTimeResponse {
        log.trace(
            "setTime",
            metadata: [
                "sec": "\(request.sec)",
                "usec": "\(request.usec)",
            ])

        var tv = timeval(tv_sec: time_t(request.sec), tv_usec: suseconds_t(request.usec))
        guard settimeofday(&tv, nil) == 0 else {
            let error = swiftErrno("settimeofday")
            log.error(
                "setTime",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "failed to settimeofday: \(error)")
        }

        return .init()
    }

    func setupEmulator(
        request: Com_Apple_Containerization_Sandbox_V3_SetupEmulatorRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SetupEmulatorResponse {
        log.debug(
            "setupEmulator",
            metadata: [
                "request": "\(request)"
            ])

        if !Binfmt.mounted() {
            throw GRPCStatus(
                code: .internalError,
                message: "\(Binfmt.path) is not mounted"
            )
        }

        do {
            let bfmt = Binfmt.Entry(
                name: request.name,
                type: request.type,
                offset: request.offset,
                magic: request.magic,
                mask: request.mask,
                flags: request.flags
            )
            try bfmt.register(binaryPath: request.binaryPath)
        } catch {
            log.error(
                "setupEmulator",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "setupEmulator: failed to register binfmt_misc entry: \(error)"
            )
        }

        return .init()
    }

    func sysctl(
        request: Com_Apple_Containerization_Sandbox_V3_SysctlRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SysctlResponse {
        log.debug(
            "sysctl",
            metadata: [
                "settings": "\(request.settings)"
            ])

        do {
            let sysctlPath = URL(fileURLWithPath: "/proc/sys/")
            for (k, v) in request.settings {
                guard let data = v.data(using: .ascii) else {
                    throw GRPCStatus(code: .internalError, message: "failed to convert \(v) to data buffer for sysctl write")
                }

                let setting =
                    sysctlPath
                    .appendingPathComponent(k.replacingOccurrences(of: ".", with: "/"))
                let fh = try FileHandle(forWritingTo: setting)
                defer { try? fh.close() }

                try fh.write(contentsOf: data)
            }
        } catch {
            log.error(
                "sysctl",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "sysctl: failed to set sysctl: \(error)"
            )
        }

        return .init()
    }

    func proxyVsock(
        request: Com_Apple_Containerization_Sandbox_V3_ProxyVsockRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ProxyVsockResponse {
        log.debug(
            "proxyVsock",
            metadata: [
                "id": "\(request.id)",
                "port": "\(request.vsockPort)",
                "guestPath": "\(request.guestPath)",
                "action": "\(request.action)",
            ])

        let proxy = VsockProxy(
            id: request.id,
            action: request.action == .into ? .dial : .listen,
            port: request.vsockPort,
            path: URL(fileURLWithPath: request.guestPath),
            udsPerms: request.guestSocketPermissions,
            log: log
        )

        do {
            try await proxy.start()
            try await state.add(proxy: proxy)
        } catch {
            try? await proxy.close()
            log.error(
                "proxyVsock",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "proxyVsock: failed to setup vsock proxy: \(error)"
            )
        }

        log.info(
            "proxyVsock started",
            metadata: [
                "id": "\(request.id)",
                "port": "\(request.vsockPort)",
                "guestPath": "\(request.guestPath)",
            ])

        return .init()
    }

    func stopVsockProxy(
        request: Com_Apple_Containerization_Sandbox_V3_StopVsockProxyRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_StopVsockProxyResponse {
        log.debug(
            "stopVsockProxy",
            metadata: [
                "id": "\(request.id)"
            ])

        do {
            let proxy = try await state.remove(proxy: request.id)
            try await proxy.close()
        } catch {
            log.error(
                "stopVsockProxy",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "stopVsockProxy: failed to stop vsock proxy: \(error)"
            )
        }

        log.info(
            "stopVsockProxy completed",
            metadata: [
                "id": "\(request.id)"
            ])

        return .init()
    }

    func mkdir(request: Com_Apple_Containerization_Sandbox_V3_MkdirRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_MkdirResponse
    {
        log.debug(
            "mkdir",
            metadata: [
                "path": "\(request.path)",
                "all": "\(request.all)",
            ])

        do {
            try FileManager.default.createDirectory(
                atPath: request.path,
                withIntermediateDirectories: request.all
            )
        } catch {
            log.error(
                "mkdir",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "mkdir: \(error)")
        }

        return .init()
    }

    func writeFile(request: Com_Apple_Containerization_Sandbox_V3_WriteFileRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_WriteFileResponse
    {
        log.debug(
            "writeFile",
            metadata: [
                "path": "\(request.path)",
                "mode": "\(request.mode)",
                "dataSize": "\(request.data.count)",
            ])

        do {
            if request.flags.createParentDirs {
                let fileURL = URL(fileURLWithPath: request.path)
                let parentDir = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true
                )
            }

            var flags = O_WRONLY
            if request.flags.createIfMissing {
                flags |= O_CREAT
            }
            if request.flags.append {
                flags |= O_APPEND
            }

            let mode = request.mode > 0 ? mode_t(request.mode) : mode_t(0644)
            let fd = open(request.path, flags, mode)
            guard fd != -1 else {
                let error = swiftErrno("open")
                throw GRPCStatus(
                    code: .internalError,
                    message: "writeFile: failed to open file: \(error)"
                )
            }

            let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try fh.write(contentsOf: request.data)
        } catch {
            log.error(
                "writeFile",
                metadata: [
                    "error": "\(error)"
                ])
            if error is GRPCStatus {
                throw error
            }
            throw GRPCStatus(
                code: .internalError,
                message: "writeFile: \(error)"
            )
        }

        return .init()
    }

    // Chunk size for streaming file transfers (1MB).
    private static let copyChunkSize = 1024 * 1024

    func copyIn(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Containerization_Sandbox_V3_CopyInChunk>,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_CopyInResponse {
        var fileHandle: FileHandle?
        var path: String = ""
        var totalBytes: Int = 0

        do {
            for try await chunk in requestStream {
                switch chunk.content {
                case .init_p(let initMsg):
                    path = initMsg.path
                    log.debug(
                        "copyIn",
                        metadata: [
                            "path": "\(path)",
                            "mode": "\(initMsg.mode)",
                            "createParents": "\(initMsg.createParents)",
                        ])

                    if initMsg.createParents {
                        let fileURL = URL(fileURLWithPath: path)
                        let parentDir = fileURL.deletingLastPathComponent()
                        try FileManager.default.createDirectory(
                            at: parentDir,
                            withIntermediateDirectories: true
                        )
                    }

                    let mode = initMsg.mode > 0 ? mode_t(initMsg.mode) : mode_t(0o644)
                    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode)
                    guard fd != -1 else {
                        throw GRPCStatus(
                            code: .internalError,
                            message: "copyIn: failed to open file '\(path)': \(swiftErrno("open"))"
                        )
                    }
                    fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                case .data(let bytes):
                    guard let fh = fileHandle else {
                        throw GRPCStatus(
                            code: .failedPrecondition,
                            message: "copyIn: received data before init message"
                        )
                    }
                    if !bytes.isEmpty {
                        try fh.write(contentsOf: bytes)
                        totalBytes += bytes.count
                    }
                case .none:
                    break
                }
            }

            log.debug(
                "copyIn complete",
                metadata: [
                    "path": "\(path)",
                    "totalBytes": "\(totalBytes)",
                ])

            return .init()
        } catch {
            log.error(
                "copyIn",
                metadata: [
                    "path": "\(path)",
                    "error": "\(error)",
                ])
            if error is GRPCStatus {
                throw error
            }
            throw GRPCStatus(
                code: .internalError,
                message: "copyIn: \(error)"
            )
        }
    }

    func copyOut(
        request: Com_Apple_Containerization_Sandbox_V3_CopyOutRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Containerization_Sandbox_V3_CopyOutChunk>,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws {
        let path = request.path
        log.debug(
            "copyOut",
            metadata: [
                "path": "\(path)"
            ])

        do {
            let fileURL = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard let fileSize = attrs[.size] as? UInt64 else {
                throw GRPCStatus(
                    code: .internalError,
                    message: "copyOut: failed to get file size for '\(path)'"
                )
            }

            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }

            // Send init message with total size.
            try await responseStream.send(
                .with {
                    $0.content = .init_p(.with { $0.totalSize = fileSize })
                }
            )

            var totalSent: UInt64 = 0
            while true {
                guard let data = try fileHandle.read(upToCount: Self.copyChunkSize), !data.isEmpty else {
                    break
                }

                try await responseStream.send(.with { $0.content = .data(data) })
                totalSent += UInt64(data.count)
            }

            log.debug(
                "copyOut complete",
                metadata: [
                    "path": "\(path)",
                    "totalBytes": "\(totalSent)",
                ])
        } catch {
            log.error(
                "copyOut",
                metadata: [
                    "path": "\(path)",
                    "error": "\(error)",
                ])
            if error is GRPCStatus {
                throw error
            }
            throw GRPCStatus(
                code: .internalError,
                message: "copyOut: \(error)"
            )
        }
    }

    func mount(request: Com_Apple_Containerization_Sandbox_V3_MountRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_MountResponse
    {
        log.debug(
            "mount",
            metadata: [
                "type": "\(request.type)",
                "source": "\(request.source)",
                "destination": "\(request.destination)",
            ])

        do {
            let mnt = ContainerizationOS.Mount(
                type: request.type,
                source: request.source,
                target: request.destination,
                options: request.options
            )

            #if os(Linux)
            try mnt.mount(createWithPerms: 0o755)
            return .init()
            #else
            fatalError("mount not supported on platform")
            #endif
        } catch {
            log.error(
                "mount",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "mount: \(error)")
        }
    }

    func umount(request: Com_Apple_Containerization_Sandbox_V3_UmountRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_UmountResponse
    {
        log.debug(
            "umount",
            metadata: [
                "path": "\(request.path)",
                "flags": "\(request.flags)",
            ])

        #if os(Linux)
        // Best effort EBUSY handle.
        for _ in 0...50 {
            let result = _umount(request.path, request.flags)
            if result == -1 {
                if errno == EBUSY {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                let error = swiftErrno("umount")

                log.error(
                    "umount",
                    metadata: [
                        "error": "\(error)"
                    ])
                throw GRPCStatus(code: .invalidArgument, message: "umount: \(error)")
            }
            break
        }
        return .init()
        #else
        fatalError("umount not supported on platform")
        #endif
    }

    func setenv(request: Com_Apple_Containerization_Sandbox_V3_SetenvRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_SetenvResponse
    {
        log.debug(
            "setenv",
            metadata: [
                "key": "\(request.key)",
                "value": "\(request.value)",
            ])

        guard _setenv(request.key, request.value, 1) == 0 else {
            let error = swiftErrno("setenv")

            log.error(
                "setEnv",
                metadata: [
                    "error": "\(error)"
                ])

            throw GRPCStatus(code: .invalidArgument, message: "setenv: \(error)")
        }
        return .init()
    }

    func getenv(request: Com_Apple_Containerization_Sandbox_V3_GetenvRequest, context: GRPC.GRPCAsyncServerCallContext)
        async throws -> Com_Apple_Containerization_Sandbox_V3_GetenvResponse
    {
        log.debug(
            "getenv",
            metadata: [
                "key": "\(request.key)"
            ])

        let env = ProcessInfo.processInfo.environment[request.key]
        return .with {
            if let env {
                $0.value = env
            }
        }
    }

    func createProcess(
        request: Com_Apple_Containerization_Sandbox_V3_CreateProcessRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_CreateProcessResponse {
        log.debug(
            "createProcess",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
                "stdin": "Port: \(request.stdin)",
                "stdout": "Port: \(request.stdout)",
                "stderr": "Port: \(request.stderr)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            var ociSpec = try JSONDecoder().decode(
                ContainerizationOCI.Spec.self,
                from: request.configuration
            )

            try ociAlterations(id: request.id, ociSpec: &ociSpec)

            guard let process = ociSpec.process else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "oci runtime spec missing process configuration"
                )
            }

            let stdioPorts = HostStdio(
                stdin: request.hasStdin ? request.stdin : nil,
                stdout: request.hasStdout ? request.stdout : nil,
                stderr: request.hasStderr ? request.stderr : nil,
                terminal: process.terminal
            )

            // This is an exec.
            if let container = await self.state.containers[request.containerID] {
                try await container.createExec(
                    id: request.id,
                    stdio: stdioPorts,
                    process: process
                )
            } else {
                // We need to make our new fangled container.
                // The process ID must match the container ID for this.
                guard request.id == request.containerID else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "init process id must match container id"
                    )
                }

                // Write the etc/hostname file in the container rootfs since some init-systems
                // depend on it.
                let hostname = ociSpec.hostname
                if let root = ociSpec.root, !hostname.isEmpty {
                    let etc = URL(fileURLWithPath: root.path).appendingPathComponent("etc")
                    try FileManager.default.createDirectory(atPath: etc.path, withIntermediateDirectories: true)
                    let hostnamePath = etc.appendingPathComponent("hostname")
                    try hostname.write(toFile: hostnamePath.path, atomically: true, encoding: .utf8)
                }

                let ctr = try await ManagedContainer(
                    id: request.id,
                    stdio: stdioPorts,
                    spec: ociSpec,
                    ociRuntimePath: request.hasOciRuntimePath ? request.ociRuntimePath : nil,
                    log: self.log
                )
                try await self.state.add(container: ctr)
            }

            return .init()
        } catch let err as ContainerizationError {
            log.error(
                "createProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "createProcess: failed to create process")
        } catch {
            log.error(
                "createProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(code: .internalError, message: "createProcess: failed to create process: \(error)")
        }
    }

    func killProcess(
        request: Com_Apple_Containerization_Sandbox_V3_KillProcessRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_KillProcessResponse {
        log.debug(
            "killProcess",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
                "signal": "\(request.signal)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            let ctr = try await self.state.get(container: request.containerID)
            try await ctr.kill(execID: request.id, request.signal)

            return .init()
        } catch let err as ContainerizationError {
            log.error(
                "killProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "killProcess: failed to kill process")
        } catch {
            log.error(
                "killProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(code: .internalError, message: "killProcess: failed to kill process: \(error)")
        }
    }

    func deleteProcess(
        request: Com_Apple_Containerization_Sandbox_V3_DeleteProcessRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_DeleteProcessResponse {
        log.debug(
            "deleteProcess",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            let ctr = try await self.state.get(container: request.containerID)

            // Are we trying to delete the container itself?
            if request.id == request.containerID {
                try await ctr.delete()
                try await state.remove(container: request.id)
            } else {
                // Or just a single exec.
                try await ctr.deleteExec(id: request.id)
            }

            return .init()
        } catch let err as ContainerizationError {
            log.error(
                "deleteProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "deleteProcess: failed to delete process")
        } catch {
            log.error(
                "deleteProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(code: .internalError, message: "deleteProcess: failed to delete process: \(error)")
        }
    }

    func startProcess(
        request: Com_Apple_Containerization_Sandbox_V3_StartProcessRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_StartProcessResponse {
        log.debug(
            "startProcess",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            let ctr = try await self.state.get(container: request.containerID)
            let pid = try await ctr.start(execID: request.id)

            return .with {
                $0.pid = pid
            }
        } catch let err as ContainerizationError {
            log.error(
                "startProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "startProcess: failed to start process")
        } catch {
            log.error(
                "startProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "startProcess: failed to start process: \(error)"
            )
        }
    }

    func resizeProcess(
        request: Com_Apple_Containerization_Sandbox_V3_ResizeProcessRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ResizeProcessResponse {
        log.debug(
            "resizeProcess",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            let ctr = try await self.state.get(container: request.containerID)
            let size = Terminal.Size(
                width: UInt16(request.columns),
                height: UInt16(request.rows)
            )
            try await ctr.resize(execID: request.id, size: size)
        } catch let err as ContainerizationError {
            log.error(
                "resizeProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "resizeProcess: failed to resize process")
        } catch {
            log.error(
                "resizeProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "resizeProcess: failed to resize process: \(error)"
            )
        }

        return .init()
    }

    func waitProcess(
        request: Com_Apple_Containerization_Sandbox_V3_WaitProcessRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_WaitProcessResponse {
        log.debug(
            "waitProcess",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            let ctr = try await self.state.get(container: request.containerID)
            let exitStatus = try await ctr.wait(execID: request.id)

            return .with {
                $0.exitCode = exitStatus.exitCode
                $0.exitedAt = Google_Protobuf_Timestamp(date: exitStatus.exitedAt)
            }
        } catch let err as ContainerizationError {
            log.error(
                "waitProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "waitProcess: failed to wait on process")
        } catch {
            log.error(
                "waitProcess",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "waitProcess: failed to wait on process: \(error)"
            )
        }
    }

    func closeProcessStdin(
        request: Com_Apple_Containerization_Sandbox_V3_CloseProcessStdinRequest, context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_CloseProcessStdinResponse {
        log.debug(
            "closeProcessStdin",
            metadata: [
                "id": "\(request.id)",
                "containerID": "\(request.containerID)",
            ])

        do {
            if !request.hasContainerID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "processes in the root of the vm not implemented"
                )
            }

            let ctr = try await self.state.get(container: request.containerID)

            try await ctr.closeStdin(execID: request.id)

            return .init()
        } catch let err as ContainerizationError {
            log.error(
                "closeProcessStdin",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(err)",
                ])
            throw err.toGRPCStatus(operation: "closeProcessStdin: failed to close process stdin")
        } catch {
            log.error(
                "closeProcessStdin",
                metadata: [
                    "id": "\(request.id)",
                    "containerID": "\(request.containerID)",
                    "error": "\(error)",
                ])
            throw GRPCStatus(
                code: .internalError,
                message: "closeProcessStdin: failed to close process stdin: \(error)"
            )
        }
    }

    func ipLinkSet(
        request: Com_Apple_Containerization_Sandbox_V3_IpLinkSetRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpLinkSetResponse {
        log.debug(
            "ipLinkSet",
            metadata: [
                "interface": "\(request.interface)",
                "up": "\(request.up)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            let mtuValue: UInt32? = request.hasMtu ? request.mtu : nil
            try session.linkSet(interface: request.interface, up: request.up, mtu: mtuValue)
        } catch {
            log.error(
                "ipLinkSet",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "ip-link-set: \(error)")
        }

        return .init()
    }

    func ipAddrAdd(
        request: Com_Apple_Containerization_Sandbox_V3_IpAddrAddRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpAddrAddResponse {
        log.debug(
            "ipAddrAdd",
            metadata: [
                "interface": "\(request.interface)",
                "ipv4Address": "\(request.ipv4Address)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            let ipv4Address = try CIDRv4(request.ipv4Address)
            try session.addressAdd(interface: request.interface, ipv4Address: ipv4Address)
        } catch {
            log.error(
                "ipAddrAdd",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "failed to set IP address on interface \(request.interface): \(error)")
        }

        return .init()
    }

    func ipRouteAddLink(
        request: Com_Apple_Containerization_Sandbox_V3_IpRouteAddLinkRequest, context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpRouteAddLinkResponse {
        log.debug(
            "ipRouteAddLink",
            metadata: [
                "interface": "\(request.interface)",
                "dstIpv4Addr": "\(request.dstIpv4Addr)",
                "srcIpv4Addr": "\(request.srcIpv4Addr)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            let dstIpv4Addr = try CIDRv4(request.dstIpv4Addr)
            let srcIpv4Addr = request.srcIpv4Addr.isEmpty ? nil : try IPv4Address(request.srcIpv4Addr)
            try session.routeAdd(
                interface: request.interface,
                dstIpv4Addr: dstIpv4Addr,
                srcIpv4Addr: srcIpv4Addr
            )
        } catch {
            log.error(
                "ipRouteAddLink",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "ip-route-add-link: \(error)")
        }

        return .init()
    }

    func ipRouteAddDefault(
        request: Com_Apple_Containerization_Sandbox_V3_IpRouteAddDefaultRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_IpRouteAddDefaultResponse {
        log.debug(
            "ipRouteAddDefault",
            metadata: [
                "interface": "\(request.interface)",
                "ipv4Gateway": "\(request.ipv4Gateway)",
            ])

        do {
            let socket = try DefaultNetlinkSocket()
            let session = NetlinkSession(socket: socket, log: log)
            let ipv4Gateway = try IPv4Address(request.ipv4Gateway)
            try session.routeAddDefault(interface: request.interface, ipv4Gateway: ipv4Gateway)
        } catch {
            log.error(
                "ipRouteAddDefault",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "failed to set default gateway on interface \(request.interface): \(error)")
        }

        return .init()
    }

    func configureDns(
        request: Com_Apple_Containerization_Sandbox_V3_ConfigureDnsRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ConfigureDnsResponse {
        let domain = request.hasDomain ? request.domain : nil
        log.debug(
            "configureDns",
            metadata: [
                "location": "\(request.location)",
                "nameservers": "\(request.nameservers)",
                "domain": "\(domain ?? "")",
                "searchDomains": "\(request.searchDomains)",
                "options": "\(request.options)",
            ])

        do {
            let etc = URL(fileURLWithPath: request.location).appendingPathComponent("etc")
            try FileManager.default.createDirectory(atPath: etc.path, withIntermediateDirectories: true)
            let resolvConf = etc.appendingPathComponent("resolv.conf")
            let config = DNS(
                nameservers: request.nameservers,
                domain: domain,
                searchDomains: request.searchDomains,
                options: request.options
            )
            let text = config.resolvConf
            log.debug("writing to path \(resolvConf.path) \(text)")
            try text.write(toFile: resolvConf.path, atomically: true, encoding: .utf8)
            log.debug("wrote resolver configuration", metadata: ["path": "\(resolvConf.path)"])
        } catch {
            log.error(
                "configureDns",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "failed to configure DNS at location \(request.location): \(error)")
        }

        return .init()
    }

    func configureHosts(
        request: Com_Apple_Containerization_Sandbox_V3_ConfigureHostsRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ConfigureHostsResponse {
        log.debug(
            "configureHosts",
            metadata: [
                "location": "\(request.location)"
            ])

        do {
            let etc = URL(fileURLWithPath: request.location).appendingPathComponent("etc")
            try FileManager.default.createDirectory(atPath: etc.path, withIntermediateDirectories: true)
            let hostsPath = etc.appendingPathComponent("hosts")

            let config = request.toCZHosts()
            let text = config.hostsFile
            try text.write(toFile: hostsPath.path, atomically: true, encoding: .utf8)

            log.debug("wrote /etc/hosts configuration", metadata: ["path": "\(hostsPath.path)"])
        } catch {
            log.error(
                "configureHosts",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "configureHosts: \(error)")
        }

        return .init()
    }

    func containerStatistics(
        request: Com_Apple_Containerization_Sandbox_V3_ContainerStatisticsRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_ContainerStatisticsResponse {
        log.debug(
            "containerStatistics",
            metadata: [
                "container_ids": "\(request.containerIds)",
                "categories": "\(request.categories)",
            ])

        do {
            // Parse requested categories (empty = all)
            let categories = Set(request.categories)
            let wantAll = categories.isEmpty
            let wantProcess = wantAll || categories.contains(.process)
            let wantMemory = wantAll || categories.contains(.memory)
            let wantCPU = wantAll || categories.contains(.cpu)
            let wantBlockIO = wantAll || categories.contains(.blockIo)
            let wantNetwork = wantAll || categories.contains(.network)
            let wantMemoryEvents = wantAll || categories.contains(.memoryEvents)

            // Get all network interfaces (skip loopback) only if needed
            let interfaces = wantNetwork ? try getNetworkInterfaces() : []

            // Get containers to query
            let containerIDs: [String]
            if request.containerIds.isEmpty {
                containerIDs = await Array(state.containers.keys)
            } else {
                containerIDs = request.containerIds
            }

            var containerStats: [Com_Apple_Containerization_Sandbox_V3_ContainerStats] = []

            for containerID in containerIDs {
                let container = try await state.get(container: containerID)

                // Only fetch cgroup stats if needed
                let cgStats: Cgroup2Stats?
                if wantProcess || wantMemory || wantCPU || wantBlockIO {
                    cgStats = try await container.stats()
                } else {
                    cgStats = nil
                }

                // Get network stats only if requested
                var networkStats: [Com_Apple_Containerization_Sandbox_V3_NetworkStats] = []
                if wantNetwork {
                    let socket = try DefaultNetlinkSocket()
                    let session = NetlinkSession(socket: socket, log: log)
                    for interface in interfaces {
                        let responses = try session.linkGet(interface: interface, includeStats: true)
                        if responses.count == 1, let stats = try responses[0].getStatistics() {
                            networkStats.append(
                                .with {
                                    $0.interface = interface
                                    $0.receivedPackets = stats.rxPackets
                                    $0.transmittedPackets = stats.txPackets
                                    $0.receivedBytes = stats.rxBytes
                                    $0.transmittedBytes = stats.txBytes
                                    $0.receivedErrors = stats.rxErrors
                                    $0.transmittedErrors = stats.txErrors
                                })
                        }
                    }
                }

                // Get memory events only if requested
                var memoryEvents: MemoryEvents?
                if wantMemoryEvents {
                    memoryEvents = try await container.getMemoryEvents()
                }

                containerStats.append(
                    mapStatsToProto(
                        containerID: containerID,
                        cgStats: cgStats,
                        networkStats: networkStats,
                        memoryEvents: memoryEvents,
                        wantProcess: wantProcess,
                        wantMemory: wantMemory,
                        wantCPU: wantCPU,
                        wantBlockIO: wantBlockIO,
                        wantNetwork: wantNetwork,
                        wantMemoryEvents: wantMemoryEvents
                    )
                )
            }

            return .with {
                $0.containers = containerStats
            }
        } catch {
            log.error(
                "containerStatistics",
                metadata: [
                    "error": "\(error)"
                ])
            throw GRPCStatus(code: .internalError, message: "containerStatistics: \(error)")
        }
    }

    func copyDirIn(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Containerization_Sandbox_V3_CopyDirInChunk>,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_CopyDirInResponse {
        var destPath = ""
        var createParents = false
        var writeHandle: FileHandle?

        let tempPath = "/tmp/\(UUID().uuidString).tar"
        defer { unlink(tempPath) }

        for try await chunk in requestStream {
            switch chunk.content {
            case .init_p(let initMsg):
                destPath = initMsg.path
                createParents = initMsg.createParents

                log.debug("copyDirIn", metadata: ["path": "\(destPath)", "createParents": "\(createParents)"])

                if createParents {
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: destPath),
                        withIntermediateDirectories: true
                    )
                }

                let fd = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                guard fd != -1 else {
                    throw GRPCStatus(
                        code: .internalError,
                        message: "copyDirIn: failed to create temp file: \(swiftErrno("open"))"
                    )
                }
                writeHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

            case .data(let bytes):
                if let wh = writeHandle, !bytes.isEmpty {
                    wh.write(bytes)
                }

            case .none:
                break
            }
        }

        guard !destPath.isEmpty else {
            throw GRPCStatus(code: .failedPrecondition, message: "copyDirIn: missing init message")
        }

        try writeHandle?.close()

        let readFD = try FileDescriptor.open(FilePath(tempPath), .readOnly)
        defer { try? readFD.close() }
        let reader = TarReader(fileDescriptor: readFD, ownsFileDescriptor: false)
        try Self.extractTar(reader: reader, to: URL(fileURLWithPath: destPath))

        log.debug("copyDirIn complete", metadata: ["path": "\(destPath)"])
        return .init()
    }

    func copyDirOut(
        request: Com_Apple_Containerization_Sandbox_V3_CopyDirOutRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Containerization_Sandbox_V3_CopyDirOutChunk>,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws {
        let path = request.path
        log.debug("copyDirOut", metadata: ["path": "\(path)"])

        // Write tar to a temp file, then stream it.
        let tempPath = "/tmp/\(UUID().uuidString).tar"
        defer { unlink(tempPath) }

        let sourceURL = URL(fileURLWithPath: path)

        let writeFD = try FileDescriptor.open(
            FilePath(tempPath),
            .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite]
        )
        let writer = TarWriter(fileDescriptor: writeFD, ownsFileDescriptor: false)
        try Self.tarDirectory(source: sourceURL, writer: writer, basePath: "")
        try writer.finalize()
        try writeFD.close()

        let readHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: tempPath))
        defer { try? readHandle.close() }

        while true {
            guard let data = try readHandle.read(upToCount: Self.copyChunkSize), !data.isEmpty else {
                break
            }
            try await responseStream.send(.with { $0.data = data })
        }

        log.debug("copyDirOut complete", metadata: ["path": "\(path)"])
    }

    /// Recursively walk a directory and write entries to a TarWriter.
    private static func tarDirectory(source: URL, writer: TarWriter, basePath: String) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in items {
            let name = item.lastPathComponent
            let entryPath = basePath.isEmpty ? name : "\(basePath)/\(name)"
            let attrs = try fm.attributesOfItem(atPath: item.path)
            let mode = (attrs[.posixPermissions] as? Int).map { UInt32($0) }
            let fileType = attrs[.type] as? FileAttributeType

            if fileType == .typeSymbolicLink {
                let target = try fm.destinationOfSymbolicLink(atPath: item.path)
                try writer.writeSymlink(path: entryPath, target: target)
            } else if fileType == .typeDirectory {
                try writer.writeDirectory(path: entryPath, mode: mode ?? 0o755)
                try tarDirectory(source: item, writer: writer, basePath: entryPath)
            } else {
                let fd = try FileDescriptor.open(FilePath(item.path), .readOnly)
                defer { try? fd.close() }
                try writer.writeFile(path: entryPath, from: fd, mode: mode ?? 0o644)
            }
        }
    }

    /// Extract a tar archive into a destination directory.
    private static func extractTar(reader: TarReader, to destURL: URL) throws {
        let fm = FileManager.default
        while let header = try reader.nextHeader() {
            let relativePath = header.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.contains("..") else {
                try reader.skipRemainingContent()
                continue
            }
            let fullURL = relativePath.isEmpty ? destURL : destURL.appending(path: relativePath)

            switch header.entryType {
            case .directory:
                try fm.createDirectory(at: fullURL, withIntermediateDirectories: true)
            case .regular, .regularAlt, .contiguous:
                let parentDir = fullURL.deletingLastPathComponent()
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                let mode = mode_t(header.mode > 0 ? header.mode : 0o644)
                let fd = open(fullURL.path, O_WRONLY | O_CREAT | O_TRUNC, mode)
                guard fd != -1 else {
                    try reader.skipRemainingContent()
                    continue
                }
                let fileFD = FileDescriptor(rawValue: fd)
                defer { try? fileFD.close() }
                try reader.readFile(to: fileFD)
            case .symbolicLink:
                try? fm.removeItem(at: fullURL)
                try fm.createSymbolicLink(atPath: fullURL.path, withDestinationPath: header.linkName)
            default:
                try reader.skipRemainingContent()
            }
        }
    }

    private func swiftErrno(_ msg: Logger.Message) -> POSIXError {
        let error = POSIXError(.init(rawValue: errno)!)
        log.error(
            msg,
            metadata: [
                "error": "\(error)"
            ])
        return error
    }

    // NOTE: This is just crummy. It works because today the assumption is
    // every NIC in the root net namespace is for the container(s), but if we
    // ever supported individual containers having their own NICs/IPs then this
    // logic needs to change. We only create ethernet devices today too, so that's
    // what this filters for as well.
    private func getNetworkInterfaces() throws -> [String] {
        let netPath = URL(filePath: "/sys/class/net")
        let interfaces = try FileManager.default.contentsOfDirectory(
            at: netPath,
            includingPropertiesForKeys: nil
        )
        return
            interfaces
            .map { $0.lastPathComponent }
            .filter { $0.hasPrefix("eth") }
    }

    private func mapStatsToProto(
        containerID: String,
        cgStats: Cgroup2Stats?,
        networkStats: [Com_Apple_Containerization_Sandbox_V3_NetworkStats],
        memoryEvents: MemoryEvents?,
        wantProcess: Bool,
        wantMemory: Bool,
        wantCPU: Bool,
        wantBlockIO: Bool,
        wantNetwork: Bool,
        wantMemoryEvents: Bool
    ) -> Com_Apple_Containerization_Sandbox_V3_ContainerStats {
        .with {
            $0.containerID = containerID

            if wantProcess, let pids = cgStats?.pids {
                $0.process = .with {
                    $0.current = pids.current
                    $0.limit = pids.max ?? 0
                }
            }

            if wantMemory, let memory = cgStats?.memory {
                $0.memory = .with {
                    $0.usageBytes = memory.usage
                    $0.limitBytes = memory.usageLimit ?? 0
                    $0.swapUsageBytes = memory.swapUsage ?? 0
                    $0.swapLimitBytes = memory.swapLimit ?? 0
                    $0.cacheBytes = memory.file
                    $0.kernelStackBytes = memory.kernelStack
                    $0.slabBytes = memory.slab
                    $0.pageFaults = memory.pgfault
                    $0.majorPageFaults = memory.pgmajfault
                    $0.inactiveFile = memory.inactiveFile
                    $0.anon = memory.anon
                }
            }

            if wantCPU, let cpu = cgStats?.cpu {
                $0.cpu = .with {
                    $0.usageUsec = cpu.usageUsec
                    $0.userUsec = cpu.userUsec
                    $0.systemUsec = cpu.systemUsec
                    $0.throttlingPeriods = cpu.nrPeriods
                    $0.throttledPeriods = cpu.nrThrottled
                    $0.throttledTimeUsec = cpu.throttledUsec
                }
            }

            if wantBlockIO, let io = cgStats?.io {
                $0.blockIo = .with {
                    $0.devices = io.entries.map { entry in
                        .with {
                            $0.major = entry.major
                            $0.minor = entry.minor
                            $0.readBytes = entry.rbytes
                            $0.writeBytes = entry.wbytes
                            $0.readOperations = entry.rios
                            $0.writeOperations = entry.wios
                        }
                    }
                }
            }

            if wantNetwork {
                $0.networks = networkStats
            }

            if wantMemoryEvents, let events = memoryEvents {
                $0.memoryEvents = .with {
                    $0.low = events.low
                    $0.high = events.high
                    $0.max = events.max
                    $0.oom = events.oom
                    $0.oomKill = events.oomKill
                }
            }
        }
    }

    func sync(
        request: Com_Apple_Containerization_Sandbox_V3_SyncRequest,
        context: GRPC.GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_SyncResponse {
        log.debug("sync")

        _sync()
        return .init()
    }

    func kill(
        request: Com_Apple_Containerization_Sandbox_V3_KillRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Com_Apple_Containerization_Sandbox_V3_KillResponse {
        log.debug(
            "kill",
            metadata: [
                "pid": "\(request.pid)",
                "signal": "\(request.signal)",
            ])

        let r = _kill(request.pid, request.signal)
        return .with {
            $0.result = r
        }
    }
}

extension Com_Apple_Containerization_Sandbox_V3_ConfigureHostsRequest {
    func toCZHosts() -> Hosts {
        let entries = self.entries.map {
            Hosts.Entry(
                ipAddress: $0.ipAddress,
                hostnames: $0.hostnames,
                comment: $0.hasComment ? $0.comment : nil
            )
        }
        return Hosts(
            entries: entries,
            comment: self.hasComment ? self.comment : nil
        )
    }
}

extension Initd {
    func ociAlterations(id: String, ociSpec: inout ContainerizationOCI.Spec) throws {
        guard var process = ociSpec.process else {
            throw ContainerizationError(
                .invalidArgument,
                message: "runtime spec without process field present"
            )
        }
        guard let root = ociSpec.root else {
            throw ContainerizationError(
                .invalidArgument,
                message: "runtime spec without root field present"
            )
        }

        if ociSpec.linux!.cgroupsPath.isEmpty {
            ociSpec.linux!.cgroupsPath = "/container/\(id)"
        }

        if process.cwd.isEmpty {
            process.cwd = "/"
        }

        // NOTE: The OCI runtime specs Username field is truthfully Windows exclusive, but we use this as a way
        // to pass through the exact string representation of a username (or username:group, uid:group etc.) a client
        // may have given us.
        let username = process.user.username.isEmpty ? "\(process.user.uid):\(process.user.gid)" : process.user.username
        let parsedUser = try User.getExecUser(
            userString: username,
            passwdPath: URL(filePath: root.path).appending(path: "etc/passwd"),
            groupPath: URL(filePath: root.path).appending(path: "etc/group")
        )
        process.user.uid = parsedUser.uid
        process.user.gid = parsedUser.gid
        process.user.additionalGids.append(contentsOf: parsedUser.sgids)
        process.user.additionalGids.append(process.user.gid)

        var seenSuppGids = Set<UInt32>()
        process.user.additionalGids = process.user.additionalGids.filter {
            seenSuppGids.insert($0).inserted
        }

        if !process.env.contains(where: { $0.hasPrefix("PATH=") }) {
            process.env.append("PATH=\(LinuxProcessConfiguration.defaultPath)")
        }

        if !process.env.contains(where: { $0.hasPrefix("HOME=") }) {
            process.env.append("HOME=\(parsedUser.home)")
        }

        // Defensive programming a tad, but ensure we have TERM set if
        // the client requested a pty.
        if process.terminal {
            let termEnv = "TERM="
            if !process.env.contains(where: { $0.hasPrefix(termEnv) }) {
                process.env.append("TERM=xterm")
            }
        }

        ociSpec.process = process
    }
}
