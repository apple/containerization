//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GRPC
import NIOPosix

/// A remote connection into the vminitd Linux guest agent via a port (vsock).
/// Used to modify the runtime environment of the Linux sandbox.
public struct Vminitd: Sendable {
    public typealias Client = Com_Apple_Containerization_Sandbox_V3_SandboxContextAsyncClient

    // Default vsock port that the agent and client use.
    public static let port: UInt32 = 1024

    private static let defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    let client: Client

    public init(client: Client) {
        self.client = client
    }

    public init(connection: FileHandle, group: MultiThreadedEventLoopGroup) {
        self.client = .init(connection: connection, group: group)
    }

    /// Close the connection to the guest agent.
    public func close() async throws {
        try await client.close()
    }
}

extension Vminitd: VirtualMachineAgent {
    /// Perform the standard guest setup necessary for vminitd to be able to
    /// run containers.
    public func standardSetup() async throws {
        try await up(name: "lo")

        try await setenv(key: "PATH", value: Self.defaultPath)

        let mounts: [ContainerizationOCI.Mount] = [
            // NOTE: /proc is always done implicitly by the guest agent.
            .init(type: "tmpfs", source: "tmpfs", destination: "/run"),
            .init(type: "sysfs", source: "sysfs", destination: "/sys"),
            .init(type: "tmpfs", source: "tmpfs", destination: "/tmp"),
            .init(type: "devpts", source: "devpts", destination: "/dev/pts", options: ["gid=5", "mode=620", "ptmxmode=666"]),
            .init(type: "cgroup2", source: "none", destination: "/sys/fs/cgroup"),
        ]
        for mount in mounts {
            try await self.mount(mount)
        }
    }

    /// Mount a filesystem in the sandbox's environment.
    public func mount(_ mount: ContainerizationOCI.Mount) async throws {
        _ = try await client.mount(
            .with {
                $0.type = mount.type
                $0.source = mount.source
                $0.destination = mount.destination
                $0.options = mount.options
            })
    }

    /// Unmount a filesystem in the sandbox's environment.
    public func umount(path: String, flags: Int32) async throws {
        _ = try await client.umount(
            .with {
                $0.path = path
                $0.flags = flags
            })
    }

    /// Create a directory inside the sandbox's environment.
    public func mkdir(path: String, all: Bool, perms: UInt32) async throws {
        _ = try await client.mkdir(
            .with {
                $0.path = path
                $0.all = all
                $0.perms = perms
            })
    }

    public func createProcess(
        id: String,
        containerID: String?,
        stdinPort: UInt32?,
        stdoutPort: UInt32?,
        stderrPort: UInt32?,
        configuration: ContainerizationOCI.Spec,
        options: Data?
    ) async throws {
        let enc = JSONEncoder()
        _ = try await client.createProcess(
            .with {
                $0.id = id
                if let stdinPort {
                    $0.stdin = stdinPort
                }
                if let stdoutPort {
                    $0.stdout = stdoutPort
                }
                if let stderrPort {
                    $0.stderr = stderrPort
                }
                if let containerID {
                    $0.containerID = containerID
                }
                $0.configuration = try enc.encode(configuration)
            })
    }

    @discardableResult
    public func startProcess(id: String, containerID: String?) async throws -> Int32 {
        let request = Com_Apple_Containerization_Sandbox_V3_StartProcessRequest.with {
            $0.id = id
            if let containerID {
                $0.containerID = containerID
            }
        }
        let resp = try await client.startProcess(request)
        return resp.pid
    }

    public func signalProcess(id: String, containerID: String?, signal: Int32) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_KillProcessRequest.with {
            $0.id = id
            $0.signal = signal
            if let containerID {
                $0.containerID = containerID
            }
        }
        _ = try await client.killProcess(request)
    }

    public func resizeProcess(id: String, containerID: String?, columns: UInt32, rows: UInt32) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_ResizeProcessRequest.with {
            if let containerID {
                $0.containerID = containerID
            }
            $0.id = id
            $0.columns = columns
            $0.rows = rows
        }
        _ = try await client.resizeProcess(request)
    }

    public func waitProcess(id: String, containerID: String?, timeoutInSeconds: Int64? = nil) async throws -> Int32 {
        let request = Com_Apple_Containerization_Sandbox_V3_WaitProcessRequest.with {
            $0.id = id
            if let containerID {
                $0.containerID = containerID
            }
        }
        var callOpts: CallOptions?
        if let timeoutInSeconds {
            var copts = CallOptions()
            copts.timeLimit = .timeout(.seconds(timeoutInSeconds))
            callOpts = copts
        }
        do {
            let resp = try await client.waitProcess(request, callOptions: callOpts)
            return resp.exitCode
        } catch {
            if let err = error as? GRPCError.RPCTimedOut {
                throw ContainerizationError(
                    .timeout,
                    message: "failed to wait for process exit within timeout of \(timeoutInSeconds!) seconds",
                    cause: err
                )
            }
            throw error
        }
    }

    public func deleteProcess(id: String, containerID: String?) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_DeleteProcessRequest.with {
            $0.id = id
            if let containerID {
                $0.containerID = containerID
            }
        }
        _ = try await client.deleteProcess(request)
    }

    public func closeProcessStdin(id: String, containerID: String?) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_CloseProcessStdinRequest.with {
            $0.id = id
            if let containerID {
                $0.containerID = containerID
            }
        }
        _ = try await client.closeProcessStdin(request)
    }

    public func up(name: String, mtu: UInt32? = nil) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_IpLinkSetRequest.with {
            $0.interface = name
            $0.up = true
            if let mtu { $0.mtu = mtu }
        }
        _ = try await client.ipLinkSet(request)
    }

    public func down(name: String) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_IpLinkSetRequest.with {
            $0.interface = name
            $0.up = false
        }
        _ = try await client.ipLinkSet(request)
    }

    /// Get an environment variable from the sandbox's environment.
    public func getenv(key: String) async throws -> String {
        let response = try await client.getenv(
            .with {
                $0.key = key
            })
        return response.value
    }

    /// Set an environment variable in the sandbox's environment.
    public func setenv(key: String, value: String) async throws {
        _ = try await client.setenv(
            .with {
                $0.key = key
                $0.value = value
            })
    }
}

/// Vminitd specific rpcs.
extension Vminitd {
    /// Sets up an emulator in the guest.
    public func setupEmulator(binaryPath: String, configuration: Binfmt.Entry) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_SetupEmulatorRequest.with {
            $0.binaryPath = binaryPath
            $0.name = configuration.name
            $0.type = configuration.type
            $0.offset = configuration.offset
            $0.magic = configuration.magic
            $0.mask = configuration.mask
            $0.flags = configuration.flags
        }
        _ = try await client.setupEmulator(request)
    }

    /// Sets the guest time.
    public func setTime(sec: Int64, usec: Int32) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_SetTimeRequest.with {
            $0.sec = sec
            $0.usec = usec
        }
        _ = try await client.setTime(request)
    }

    /// Set the provided sysctls inside the Sandbox's environment.
    public func sysctl(settings: [String: String]) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_SysctlRequest.with {
            $0.settings = settings
        }
        _ = try await client.sysctl(request)
    }

    /// Add an IP address to the sandbox's network interfaces.
    public func addressAdd(name: String, address: String) async throws {
        _ = try await client.ipAddrAdd(
            .with {
                $0.interface = name
                $0.address = address
            })
    }

    /// Set the default route in the sandbox's environment.
    public func routeAddDefault(name: String, gateway: String) async throws {
        _ = try await client.ipRouteAddDefault(
            .with {
                $0.interface = name
                $0.gateway = gateway
            })
    }

    /// Configure DNS within the sandbox's environment.
    public func configureDNS(config: DNS, location: String) async throws {
        _ = try await client.configureDns(
            .with {
                $0.location = location
                $0.nameservers = config.nameservers
                if let domain = config.domain {
                    $0.domain = domain
                }
                $0.searchDomains = config.searchDomains
                $0.options = config.options
            })
    }

    /// Configure /etc/hosts within the sandbox's environment.
    public func configureHosts(config: Hosts, location: String) async throws {
        _ = try await client.configureHosts(config.toAgentHostsRequest(location: location))
    }

    /// Perform a sync call.
    public func sync() async throws {
        _ = try await client.sync(.init())
    }

    public func kill(pid: Int32, signal: Int32) async throws -> Int32 {
        let response = try await client.kill(
            .with {
                $0.pid = pid
                $0.signal = signal
            })
        return response.result
    }

    /// Syncing shutdown will send a SIGTERM to all processes
    /// and wait, perform a sync operation, then issue a SIGKILL
    /// to the remaining processes before syncing again.
    public func syncingShutdown() async throws {
        _ = try await self.kill(pid: -1, signal: SIGTERM)
        try await Task.sleep(for: .milliseconds(10))
        try await self.sync()

        _ = try await self.kill(pid: -1, signal: SIGKILL)
        try await Task.sleep(for: .milliseconds(10))
        try await self.sync()
    }
}

extension Hosts {
    func toAgentHostsRequest(location: String) -> Com_Apple_Containerization_Sandbox_V3_ConfigureHostsRequest {
        Com_Apple_Containerization_Sandbox_V3_ConfigureHostsRequest.with {
            $0.location = location
            if let comment {
                $0.comment = comment
            }
            $0.entries = entries.map {
                let entry = $0
                return Com_Apple_Containerization_Sandbox_V3_ConfigureHostsRequest.HostsEntry.with {
                    if let comment = entry.comment {
                        $0.comment = comment
                    }
                    $0.ipAddress = entry.ipAddress
                    $0.hostnames = entry.hostnames
                }
            }
        }
    }
}

extension Vminitd.Client {
    public init(socket: String, group: MultiThreadedEventLoopGroup) {
        var config = ClientConnection.Configuration.default(
            target: .unixDomainSocket(socket),
            eventLoopGroup: group
        )
        config.maximumReceiveMessageLength = Int(64.mib())
        config.connectionBackoff = ConnectionBackoff(retries: .upTo(5))

        self = .init(channel: ClientConnection(configuration: config))
    }

    public init(connection: FileHandle, group: MultiThreadedEventLoopGroup) {
        var config = ClientConnection.Configuration.default(
            target: .connectedSocket(connection.fileDescriptor),
            eventLoopGroup: group
        )
        config.maximumReceiveMessageLength = Int(64.mib())
        config.connectionBackoff = ConnectionBackoff(retries: .upTo(5))

        self = .init(channel: ClientConnection(configuration: config))
    }

    public func close() async throws {
        try await self.channel.close().get()
    }
}
