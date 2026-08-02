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

import Containerization
import ContainerizationOCI
import Foundation

#if os(macOS)

extension IntegrationSuite {
    /// Run a docker daemon inside the guest and report what its own container
    /// saw.
    ///
    /// The daemon is given what docker's `--privileged` gives its own dind
    /// containers: every capability, no masked or read-only paths, and the
    /// devices it needs. Those devices arrive from the guest kernel at 0600
    /// root, so the spec asks for the permissions a udev host applies.
    @available(macOS 26.0, *)
    private func nestedDocker(id: String, rootless: Bool) async throws -> String {
        let bs = try await bootstrap(
            id,
            reference: rootless
                ? "docker.io/library/docker:29-dind-rootless"
                : "docker.io/library/docker:29-dind",
            capacityInBytes: 8.gib())

        let network = try VmnetNetwork()
        var manager = try ContainerManager(vmm: bs.vmm, network: network)
        defer { try? manager.delete(id) }

        let socket = rootless ? "unix:///run/user/1000/docker.sock" : "unix:///var/run/docker.sock"
        let buffer = BufferWriter()
        let container = try await manager.create(
            id, image: bs.image, rootfs: bs.rootfs
        ) { config in
            // Only the rootless daemon needs these: it reaches slirp4netns
            // through /dev/net/tun, where a root daemon bridges and does not.
            if rootless {
                config.devices = [
                    ContainerizationOCI.LinuxDevice(
                        path: "/dev/net/tun", type: "c", major: 10, minor: 200,
                        fileMode: 0o666, uid: 0, gid: 0),
                    ContainerizationOCI.LinuxDevice(
                        path: "/dev/fuse", type: "c", major: 10, minor: 229,
                        fileMode: 0o666, uid: 0, gid: 0),
                ]
            }
            config.readonlyPaths = []
            config.maskedPaths = []
            config.process.capabilities = .allCapabilities
            if rootless {
                config.process.user = ContainerizationOCI.User(uid: 1000, gid: 1000)
            }
            config.process.environmentVariables = [
                "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
                "HOME=" + (rootless ? "/home/rootless" : "/root"),
                "XDG_RUNTIME_DIR=/run/user/1000",
                "DOCKER_HOST=" + socket,
            ]
            config.process.arguments = [
                "/bin/sh", "-c",
                "mkdir -p /run/user/1000; "
                    + "dockerd-entrypoint.sh >/tmp/dockerd.log 2>&1 & "
                    + "i=0; while [ $i -lt 90 ]; do "
                    + "docker version >/dev/null 2>&1 && break; i=$((i+1)); sleep 1; done; "
                    + "docker run --rm -m 64m docker.io/library/alpine:3.20 "
                    + "sh -c 'echo NESTED_RUN_OK; echo LIMIT=$(cat /sys/fs/cgroup/memory.max)' "
                    + "2>&1 | tail -2; "
                    + "tail -3 /tmp/dockerd.log",
            ]
            config.process.stdout = buffer
            config.bootLog = bs.bootLog
        }
        try await container.create()
        try await container.start()
        _ = try await container.wait()
        try await container.stop()
        return String(data: buffer.data, encoding: .utf8) ?? ""
    }

    /// A docker daemon running as an ordinary user, under RootlessKit, which
    /// reaches `/dev/net/tun` for slirp4netns and `/dev/fuse` for its storage.
    @available(macOS 26.0, *)
    func testDindRootless() async throws {
        let out = try await nestedDocker(id: "test-dind-rootless", rootless: true)
        guard out.contains("NESTED_RUN_OK") else {
            throw IntegrationError.assert(msg: "nothing ran under nested docker: '\(out)'")
        }
    }

    /// A docker daemon running as root, which reaches cgroups directly and so
    /// holds its own containers to the limits they were given. Rootless docker
    /// takes the `none` cgroup driver when there is no systemd to delegate to
    /// it, and drops those limits (`cgroupDriver`, moby daemon/daemon_unix.go).
    @available(macOS 26.0, *)
    func testDindLimits() async throws {
        let out = try await nestedDocker(id: "test-dind-limits", rootless: false)
        guard out.contains("NESTED_RUN_OK") else {
            throw IntegrationError.assert(msg: "nothing ran under nested docker: '\(out)'")
        }
        // The 64m the nested container was run with, in bytes.
        guard out.contains("LIMIT=67108864") else {
            throw IntegrationError.assert(
                msg: "nested container was not held to its limit: '\(out)'")
        }
    }
}

#endif
