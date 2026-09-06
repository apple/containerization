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

#if os(Linux)
import CloudHypervisor
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import NIOCore
import NIOPosix
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Cloud-hypervisor backed virtual machine instance.
///
/// One CH subprocess per VM. Connects to the same `Vminitd` guest agent the
/// macOS path uses, so guest-side semantics are unchanged. This file is the
/// D1 scaffold — `start`/`stop`/`dialAgent`/`dial`/`listen` throw
/// `.unsupported` until D3–D5 fill them in. Hotplug methods delegate to
/// `CHHotplugProvider` (stubbed in D0, real in D2).
public final class CHVirtualMachineInstance: Sendable {
    public typealias Agent = Vminitd

    /// VM-instance configuration. Mirrors the macOS `VZVirtualMachineInstance.Configuration`,
    /// minus rosetta / nested-virt (which are macOS-only concepts).
    public struct Configuration: Sendable {
        public var cpus: Int
        public var memoryInBytes: UInt64
        public var mountsByID: [String: [Mount]]
        public var interfaces: [any Interface]
        public var kernel: Kernel?
        public var initialFilesystem: Mount?
        public var bootLog: BootLog?
        public var extensions: [any Sendable] = []

        public init() {
            self.cpus = 4
            self.memoryInBytes = 1024 * 1024 * 1024
            self.mountsByID = [:]
            self.interfaces = []
        }
    }

    /// One boot-time virtio-blk disk. Built deterministically in `init` so
    /// `start()`'s `VmConfig.disks` ordering matches the allocator letters.
    struct BootDisk: Sendable {
        let mount: Mount
        let containerId: String?  // nil for rootfs
        let letter: Character
    }

    // MARK: - State

    private let _state: Mutex<VirtualMachineInstanceState>
    public var state: VirtualMachineInstanceState {
        _state.withLock { $0 }
    }

    public var mounts: [String: [AttachedFilesystem]] {
        hotplug.mounts
    }

    /// Cloud-hypervisor exposes one virtio-fs device per source-hash tag, so
    /// guests must mount each tag separately at `/run/virtiofs/<tag>` rather
    /// than using a single unified-share device.
    public var virtiofsLayout: VirtiofsLayout { .perTag }

    /// Block-letter allocator shared between the boot wiring (already
    /// reserved in `init` via `bootDisks`) and runtime hotplug (D2).
    let blockAllocator: any AddressAllocator<Character>

    /// Boot-time disks in the order their letters were allocated. D3 maps
    /// these into `VmConfig.disks`.
    let bootDisks: [BootDisk]

    /// Owned resources
    let workDir: URL
    let config: Configuration
    let chProcess: CHProcess
    let client: CloudHypervisor.Client
    let hotplug: CHHotplugProvider
    let virtiofsdBinaryOverride: URL?
    let group: any EventLoopGroup
    private let ownsGroup: Bool
    private let lock: AsyncLock
    private let timeSyncer: TimeSyncer
    let logger: Logger?

    /// Pre-bound vsock listener pool for stdio. apple/container's
    /// `--virtualization` mode hands the cloud-hypervisor child process a
    /// snapshotted filesystem view at fork time, so files written under the
    /// per-VM workDir AFTER cloud-hypervisor starts are invisible to CH.
    /// We work around this by binding a fixed range of `vsock.sock_<port>`
    /// listener files BEFORE launching CH; `vm.listen(_:)` then lends out
    /// pre-bound slots from this pool instead of binding on demand.
    ///
    /// The pool bounds *concurrent* streams, not the VM's lifetime total: a
    /// slot outlives each of its tenants (see `CHStdioPortSlot`) and the host
    /// port allocator reuses released numbers (see `VsockPortAllocator`).
    /// Range covers `LinuxContainer.hostVsockPorts` initial value
    /// (`0x10000000`) through the next `stdioPoolSize` sequential ports —
    /// enough for `[stdin,stdout,stderr] x N` concurrent processes per VM.
    /// Sized for a pod's worth of containers plus concurrent `exec`s (probes,
    /// `kubectl exec`) rather than for one container: at three ports per
    /// process, 64 covers 21 concurrent processes. Idle slots cost one fd
    /// each, so the headroom is cheap.
    ///
    /// A `listen(_:)` for a port outside the range still works — it binds on
    /// demand and joins the pool, which is correct on any host where CH can see
    /// socket files created after it forked, and warns because that is exactly
    /// what the dev container cannot do.
    static let stdioPoolBase: UInt32 = 0x1000_0000
    static let stdioPoolSize: Int = 64
    /// Slots keyed by port, filled in `start()` and held until `stop()`.
    /// Entries are lent out, never removed.
    private let _stdioPool: Mutex<[UInt32: CHStdioPortSlot]>

    public convenience init(
        group: (any EventLoopGroup)? = nil,
        runtimeRoot: URL,
        chBinary: URL,
        virtiofsdBinary: URL?,
        logger: Logger? = nil,
        with: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try with(&config)
        try self.init(
            group: group,
            config: config,
            runtimeRoot: runtimeRoot,
            chBinary: chBinary,
            virtiofsdBinary: virtiofsdBinary,
            logger: logger
        )
    }

    init(
        group: (any EventLoopGroup)?,
        config: Configuration,
        runtimeRoot: URL,
        chBinary: URL,
        virtiofsdBinary: URL?,
        logger: Logger?
    ) throws {
        // 1. Working directory: per-instance under runtimeRoot. Mode 0o700
        //    so the per-VM UDS sockets inside (api.sock, vsock.sock, vfs-*)
        //    aren't reachable by other local users — the gRPC channel into
        //    vminitd has no peer authentication, so socket-file perms are
        //    the trust boundary.
        let workDir = runtimeRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.workDir = workDir

        // 2. Block allocator + boot inventory. Walks rootfs first, then
        //    mountsByID sorted by container id, allocating disk letters in
        //    that order. The same allocator is later handed to the hotplug
        //    provider so runtime add-disk picks up where boot wiring left off.
        let allocator = Character.blockDeviceTagAllocator()
        let inventory = try config.bootInventory(allocator: allocator)
        self.blockAllocator = allocator
        self.bootDisks = inventory.bootDisks

        // 3. EventLoopGroup
        if let group {
            self.ownsGroup = false
            self.group = group
        } else {
            self.ownsGroup = true
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }

        // 4. CHProcess + REST client. The api socket lives next to the workDir.
        let apiSocket = workDir.appendingPathComponent("api.sock")
        self.chProcess = CHProcess(
            config: .init(
                binary: chBinary,
                apiSocketPath: apiSocket,
                bootLog: config.bootLog
            ),
            logger: logger
        )
        self.client = try CloudHypervisor.Client(
            socketPath: apiSocket,
            eventLoopGroup: self.group,
            logger: logger ?? Logger(label: "CloudHypervisor.Client")
        )

        // 5. Hotplug provider — owns the mount registry, seeded with the
        //    boot inventory so registerMounts can append to it.
        self.hotplug = CHHotplugProvider(
            client: self.client,
            workDir: workDir,
            virtiofsdBinary: virtiofsdBinary,
            allocator: allocator,
            initialMounts: inventory.attachments,
            logger: logger
        )

        // 6. Misc
        self.config = config
        self.virtiofsdBinaryOverride = virtiofsdBinary
        self.logger = logger
        self.lock = .init()
        self.timeSyncer = .init(logger: logger)
        self._state = Mutex(.stopped)
        self._stdioPool = Mutex([:])
    }

    /// Mutate the mount registry. Forwards to the hotplug provider, which
    /// owns the registry. Kept on the instance for parity with the macOS
    /// path's `withMountRegistry` API.
    func withMountRegistry<T: Sendable>(_ body: (inout sending [String: [AttachedFilesystem]]) throws -> sending T) rethrows -> T {
        try hotplug.withMountRegistry(body)
    }
}

// MARK: - VirtualMachineInstance conformance (stubbed; D3–D5 fill these in)

extension CHVirtualMachineInstance: VirtualMachineInstance {
    public func start() async throws {
        try await lock.withLock { _ in
            guard self.state == .stopped else {
                throw ContainerizationError(
                    .invalidState,
                    message: "virtual machine is not stopped (\(self.state))"
                )
            }
            self._state.withLock { $0 = .starting }

            do {
                var vmConfig = try await self.buildVmConfig()
                for ext in self.config.extensions.compactMap({ $0 as? any CHInstanceExtension }) {
                    try ext.configureCH(&vmConfig)
                }
                let finalConfig = vmConfig

                // Pre-bind the stdio vsock listener pool before launching CH.
                // CH inherits a fs snapshot at fork time and is blind to
                // anything we add to workDir after — see `_stdioPool` doc.
                try self.prebindStdioPool()

                try await self.chProcess.start()

                try await chCall { try await self.client.vmCreate(finalConfig) }
                try await chCall { try await self.client.vmBoot() }

                let fh = try await self.dialVminitdWithRetries()
                let agent = try await Vminitd(connection: fh, group: self.group)
                await self.timeSyncer.start(context: agent)

                for ext in self.config.extensions.compactMap({ $0 as? any CHInstanceExtension }) {
                    try ext.didCreate(self)
                }

                self._state.withLock { $0 = .running }
            } catch {
                self.logger?.warning("CH VM start failed; tearing down partial resources: \(error)")
                await self.teardownAfterFailedStart()
                self._state.withLock { $0 = .stopped }
                throw error
            }
        }
    }

    /// Reverse the side effects of any partially-completed `start()`:
    /// terminate cloud-hypervisor, kill registered virtiofsd processes,
    /// close pre-bound stdio listener fds, remove the workDir, and shut
    /// down the owned event-loop group. All steps are best-effort and
    /// safe to invoke whether the corresponding `start()` step ran or not.
    private func teardownAfterFailedStart() async {
        try? await self.timeSyncer.close()

        // chProcess.terminate() is a no-op if `start()` never reached the
        // spawn — otherwise SIGTERM / SIGKILL ladder + reap.
        await self.chProcess.terminate(graceSeconds: 5)

        // Kills every virtiofsd registered by buildVmConfig (boot-time) or
        // by an in-flight hotplug. Empty if neither ran.
        await self.hotplug.shutdown()

        // Stop the stdio accept loops and close their listening fds. The
        // socket files unlink with workDir below.
        self.shutdownStdioSlots()

        try? FileManager.default.removeItem(at: self.workDir)

        // Drain the AHC HTTP client before shutting down the shared
        // event-loop group, same rationale as `stop()`: AHC's deferred
        // connection cleanup must not outlive the group it's parked on.
        try? await self.client.shutdown()

        if self.ownsGroup {
            try? await self.group.shutdownGracefully()
        }
    }

    public func stop() async throws {
        try await lock.withLock { _ in
            guard self.state == .running else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }
            self._state.withLock { $0 = .stopping }

            try? await self.timeSyncer.close()

            for ext in self.config.extensions.compactMap({ $0 as? any CHInstanceExtension }) {
                try? await ext.willStop(self)
            }

            // Best-effort graceful shutdown via REST. The CH process may
            // already be on its way out, so swallow errors from these.
            _ = try? await chCall { try await self.client.vmShutdown() }
            _ = try? await chCall { try await self.client.vmmShutdown() }

            await self.chProcess.terminate(graceSeconds: 10)
            await self.hotplug.shutdown()

            // Drain the AHC HTTP client before tearing down the shared
            // event-loop group. AHC parks deferred connection-cleanup
            // work on the group's event loops after each response; if we
            // shut the group down with that work still pending, NIO
            // prints "Cannot schedule tasks on an EventLoop that has
            // already shut down" (and will hard-crash in future NIO
            // releases). Must run after the last `chCall` above and
            // before `group.shutdownGracefully()` below.
            try? await self.client.shutdown()

            // Stop every stdio accept loop and close its listening socket.
            // The socket files themselves are removed when workDir is
            // unlinked below.
            self.shutdownStdioSlots()

            if self.ownsGroup {
                try? await self.group.shutdownGracefully()
            }

            try? FileManager.default.removeItem(at: self.workDir)

            self._state.withLock { $0 = .stopped }
        }
    }

    public func dialAgent() async throws -> Vminitd {
        try await lock.withLock { _ in
            try self.requireRunning()
            let fh = try await chVsockDial(
                baseSocket: self.workDir.appendingPathComponent("vsock.sock"),
                port: Vminitd.port
            )
            return try await Vminitd(connection: fh, group: self.group)
        }
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        try await lock.withLock { _ in
            try self.requireRunning()
            return try await chVsockDial(
                baseSocket: self.workDir.appendingPathComponent("vsock.sock"),
                port: port
            )
        }
    }

    /// Reject vsock dials when the VM isn't actually running. Without this,
    /// a dial issued after `stop()` (or before `start()` finished) raced
    /// against `workDir` removal and surfaced as an opaque "connect: No
    /// such file or directory" instead of a clear lifecycle error.
    private func requireRunning() throws {
        let current = self.state
        guard current == .running else {
            throw ContainerizationError(
                .invalidState,
                message: "vm is not running (state=\(current))"
            )
        }
    }

    public func listen(_ port: UInt32) throws -> VsockListener {
        if let slot = _stdioPool.withLock({ $0[port] }) {
            return try lend(slot)
        }

        // A port outside the pre-bound range binds on demand and then joins the
        // pool, so it recycles between tenants exactly like a pre-bound one.
        // Binding on demand is correct wherever CH can see socket files created
        // after it forked — everywhere except the `--virtualization` dev
        // container, which is what the warning is for.
        let poolEnd = Self.stdioPoolBase + UInt32(Self.stdioPoolSize)
        logger?.warning(
            """
            vsock port \(port) is outside the pre-bound range \(Self.stdioPoolBase)..<\(poolEnd); \
            binding on demand. Under apple/container --virtualization cloud-hypervisor cannot see \
            socket files created after it forked, so the guest's dial to this port will be reset — \
            raise CHVirtualMachineInstance.stdioPoolSize if this host needs more concurrent streams.
            """
        )
        let path = chVsockListenSocketPath(
            baseSocket: workDir.appendingPathComponent("vsock.sock"),
            port: port
        )
        let listenFd = try chVsockBindListener(at: path)
        let slot = CHStdioPortSlot(port: port, path: path, listenFd: listenFd)
        _stdioPool.withLock { $0[port] = slot }
        return try lend(slot)
    }

    /// Lend `slot` to a fresh listener for the duration of one stdio stream.
    /// The socket and its accept loop stay up when that listener finishes,
    /// ready for the port's next tenant — see `CHStdioPortSlot`.
    private func lend(_ slot: CHStdioPortSlot) throws -> VsockListener {
        logger?.debug("vsock listen claiming slot port=\(slot.port) path=\(slot.path.path)")
        let listener = VsockListener(port: slot.port) { [slot, logger] _ in
            logger?.debug("vsock listen releasing slot port=\(slot.port)")
            slot.relinquish()
        }
        try slot.claim(by: listener)
        slot.startAcceptingIfNeeded(logger: logger)
        return listener
    }

    /// Bind every port in `stdioPoolBase..<stdioPoolBase+stdioPoolSize` as
    /// a listening UDS at `<workDir>/vsock.sock_<port>`. Must run before
    /// `chProcess.start()` so the files end up in CH's snapshot view of
    /// the workDir. The sockets stay bound for the life of the VM; `stop()`
    /// shuts the slots down and removes `workDir` with the files in it.
    private func prebindStdioPool() throws {
        let base = workDir.appendingPathComponent("vsock.sock")
        var pool: [UInt32: CHStdioPortSlot] = [:]
        pool.reserveCapacity(Self.stdioPoolSize)
        do {
            for offset in 0..<UInt32(Self.stdioPoolSize) {
                let port = Self.stdioPoolBase + offset
                let path = chVsockListenSocketPath(baseSocket: base, port: port)
                let fd = try chVsockBindListener(at: path)
                pool[port] = CHStdioPortSlot(port: port, path: path, listenFd: fd)
            }
        } catch {
            // Roll back any successfully-bound slots so we don't leak them on
            // a partial failure. No accept loops are running yet, so shutdown
            // closes the fds directly.
            for slot in pool.values {
                slot.shutdown()
                try? FileManager.default.removeItem(at: slot.path)
            }
            throw error
        }
        _stdioPool.withLock { $0 = pool }
        logger?.debug("vsock stdio pool prebound \(pool.count) ports starting at \(Self.stdioPoolBase)")
    }

    public func hotplug(_ block: Mount, id: String) async throws -> AttachedFilesystem {
        try await hotplug.hotplug(block, id: id)
    }

    public func releaseHotplug(id: String) async throws {
        try await hotplug.releaseHotplug(id: id)
    }

    public func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        try await hotplug.hotplugVirtioFS(mounts, id: id)
    }

    public func releaseVirtioFS(id: String) async throws {
        try await hotplug.releaseVirtioFS(id: id)
    }

    public func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws {
        try hotplug.registerMounts(id: id, rootfs: rootfs, additionalMounts: additionalMounts)
    }
}

// MARK: - VmConfig + vminitd dial helpers

extension CHVirtualMachineInstance {
    /// Build the cloud-hypervisor `VmConfig` from `config`. Spawns one
    /// `virtiofsd` per unique boot-time virtiofs source-hash tag and registers
    /// each with the hotplug provider so `releaseVirtioFS(id:)` and `stop()`
    /// can reclaim them.
    private func buildVmConfig() async throws -> CloudHypervisor.VmConfig {
        guard let kernel = config.kernel else {
            throw ContainerizationError(.invalidArgument, message: "kernel is required for cloud-hypervisor backend")
        }
        guard let rootfs = config.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "initialFilesystem is required for cloud-hypervisor backend")
        }

        // Disks: rootfs forced read-only at the device level; container disks
        // honor their `ro` option through chDiskConfig.
        var disks: [CloudHypervisor.DiskConfig] = []
        for bd in bootDisks {
            let chId = bd.containerId.map { "blk-\($0)-\(bd.letter)" } ?? "rootfs"
            if var disk = bd.mount.chDiskConfig(id: chId) {
                if bd.containerId == nil {
                    disk.readonly = true
                }
                disks.append(disk)
            }
        }

        // Virtiofs: group all .virtiofs mounts in mountsByID by source-hash
        // tag, spawn one virtiofsd per tag, build matching FsConfigs.
        var byTag: [String: (mounts: [Mount], owners: [String])] = [:]
        for cid in config.mountsByID.keys.sorted() {
            guard let mounts = config.mountsByID[cid] else { continue }
            for mount in mounts {
                guard case .virtiofs = mount.runtimeOptions else { continue }
                let tag = try hashFilePath(path: mount.source)
                var entry = byTag[tag] ?? (mounts: [], owners: [])
                entry.mounts.append(mount)
                if !entry.owners.contains(cid) {
                    entry.owners.append(cid)
                }
                byTag[tag] = entry
            }
        }

        var fsConfigs: [CloudHypervisor.FsConfig] = []
        // Resolve virtiofsd lazily — only if we actually have any virtiofs
        // mounts at boot. A block-only VM doesn't require virtiofsd.
        let resolvedVirtiofsdBinary: URL? =
            byTag.isEmpty
            ? nil
            : try CHVirtualMachineManager.resolveBinary(virtiofsdBinaryOverride, name: "virtiofsd")
        for (tag, entry) in byTag {
            guard let source = entry.mounts.first?.source else { continue }
            guard let binary = resolvedVirtiofsdBinary else { continue }
            let socket = chVirtiofsSocketURL(workDir: workDir, tag: tag)
            let readonly = entry.mounts.allSatisfy { $0.options.contains("ro") }
            let chDeviceId = "fs-\(tag)"

            let process = VirtiofsdProcess(
                config: .init(
                    binary: binary,
                    socketPath: socket,
                    sharedDir: URL(fileURLWithPath: source),
                    readonly: readonly
                ),
                logger: logger
            )
            try await process.start()

            hotplug.recordBootTimeVirtiofs(
                tag: tag,
                process: process,
                chDeviceId: chDeviceId,
                ownerIds: entry.owners
            )

            fsConfigs.append(
                CloudHypervisor.FsConfig(
                    tag: tag,
                    socket: socket.path,
                    id: chDeviceId
                )
            )
        }

        let net: [CloudHypervisor.NetConfig] = try config.interfaces.compactMap {
            try ($0 as? any CHInterface)?.chNetConfig()
        }

        let vsock = CloudHypervisor.VsockConfig(
            cid: 3,
            socket: workDir.appendingPathComponent("vsock.sock").path
        )

        let payload = CloudHypervisor.PayloadConfig(
            kernel: kernel.path.path,
            cmdline: kernel.linuxCommandline(initialFilesystem: rootfs)
        )

        return CloudHypervisor.VmConfig(
            cpus: .init(bootVcpus: config.cpus, maxVcpus: config.cpus),
            // `shared: true` is required as soon as any vhost-user device (e.g.
            // virtiofsd) is attached — CH rejects `vm.boot` with "Using
            // vhost-user requires using shared memory or huge pages" otherwise.
            // We set it unconditionally because virtiofs can be added via
            // hotplug after boot (CHHotplugProvider.hotplugVirtioFS), and the
            // memory config can't be changed once the VM has booted. The
            // MAP_SHARED-backed RAM has negligible runtime impact.
            memory: .init(
                size: Self.alignMemorySize(config.memoryInBytes),
                shared: true
            ),
            payload: payload,
            disks: disks.isEmpty ? nil : disks,
            net: net.isEmpty ? nil : net,
            fs: fsConfigs.isEmpty ? nil : fsConfigs,
            vsock: vsock,
            // Kernel cmdline is `console=hvc0`, so userspace (vminitd) writes
            // to hvc0 — capture that to the bootlog. We deliberately disable
            // the pl011 (`serial`) UART entirely with `.Off`. Any non-Off mode
            // makes cloud-hypervisor APPEND `earlycon=pl011,mmio,0x...` to
            // the kernel cmdline (see CH device_manager.rs add_serial_device),
            // which forces every early-boot printk character through an MMIO
            // trap into CH's pl011 emulator and adds ~1.5s to VM boot. We
            // don't need pl011 — virtio-console is enough — so just turn it
            // off. To diagnose pre-virtio-console boot, switch to `.File` and
            // re-add `earlycon=pl011,mmio,0x09000000` to the cmdline.
            console: Self.consoleConfig(forBootLog: config.bootLog),
            serial: .init(mode: .Off)
        )
    }

    /// Round `bytes` up to the nearest 2 MiB boundary. Cloud Hypervisor
    /// rejects `vm.boot` with "Memory size is misaligned with default page
    /// size or its hugepage size" if the memory size isn't a multiple of the
    /// guest's page size; 2 MiB is a multiple of both 4 KiB and 64 KiB pages
    /// and the standard hugepage size on aarch64.
    private static func alignMemorySize(_ bytes: UInt64) -> UInt64 {
        let alignment: UInt64 = 2 * 1024 * 1024
        let remainder = bytes % alignment
        return remainder == 0 ? bytes : bytes + (alignment - remainder)
    }

    private static func consoleConfig(forBootLog bootLog: BootLog?) -> CloudHypervisor.ConsoleConfig {
        guard let bootLog else { return .init(mode: .Null) }
        switch bootLog.base {
        case .file(let path, _):
            return .init(mode: .File, file: path.path)
        case .fileHandle:
            // Cloud Hypervisor's File mode requires a path. For raw FDs we
            // could route through a pipe/relay later; for v1 fall back to
            // null to avoid silently dropping logs to a wrong place.
            return .init(mode: .Null)
        }
    }

    /// Bounded retry loop for dialing the vminitd vsock port. Absorbs the
    /// short delay between `vm.boot` and the guest agent advertising the
    /// CONNECT/OK protocol on the host UDS. Vminitd typically becomes ready
    /// within a few hundred ms of `vm.boot` returning, so we poll fast at
    /// 10 ms intervals (capped at 50 ms) to avoid burning wall-clock in
    /// exponential backoff while the guest is already up. Deadline stays
    /// at 60s as a safety net for the cold-cache long tail.
    private func dialVminitdWithRetries(
        deadline: Duration = .seconds(60),
        initialDelay: Duration = .milliseconds(10)
    ) async throws -> FileHandle {
        let baseSocket = workDir.appendingPathComponent("vsock.sock")
        let clock = ContinuousClock()
        let stop = clock.now.advanced(by: deadline)
        var delay = initialDelay
        var lastError: any Error = ContainerizationError(.timeout, message: "could not dial vminitd")
        while clock.now < stop {
            do {
                return try await chVsockDial(baseSocket: baseSocket, port: Vminitd.port)
            } catch {
                lastError = error
                try? await Task.sleep(for: delay)
                if delay < .milliseconds(50) {
                    delay = delay * 2
                }
            }
        }
        throw ContainerizationError(.timeout, message: "could not dial vminitd within \(deadline): \(lastError)")
    }

    /// Stop every stdio accept loop and release its listening socket.
    /// Idempotent per slot, so the failed-start and `stop()` paths can both
    /// call it.
    private func shutdownStdioSlots() {
        let slots = self._stdioPool.withLock { pool -> [CHStdioPortSlot] in
            let slots = Array(pool.values)
            pool.removeAll()
            return slots
        }
        for slot in slots {
            slot.shutdown()
        }
    }
}

// MARK: - Boot inventory

extension CHVirtualMachineInstance.Configuration {
    /// Walks boot-time mounts in deterministic order (rootfs first, then
    /// `mountsByID` sorted by container id, then each container's mounts in
    /// input order), allocating disk letters for virtio-blk mounts and seeding
    /// the per-container `AttachedFilesystem` registry.
    ///
    /// The allocator is shared with the runtime hotplug provider, so block
    /// hotplug picks up at the next free letter after boot.
    func bootInventory(
        allocator: any AddressAllocator<Character>
    ) throws -> (attachments: [String: [AttachedFilesystem]], bootDisks: [CHVirtualMachineInstance.BootDisk]) {
        var bootDisks: [CHVirtualMachineInstance.BootDisk] = []
        var attachments: [String: [AttachedFilesystem]] = [:]

        // Rootfs is not part of mountsByID. If it's a block device, it claims
        // the first letter (vda) so the kernel cmdline `root=/dev/vda` is right.
        if let rootfs = self.initialFilesystem, rootfs.isBlock {
            let letter = try allocator.allocate()
            bootDisks.append(.init(mount: rootfs, containerId: nil, letter: letter))
        }

        for cid in self.mountsByID.keys.sorted() {
            guard let mounts = self.mountsByID[cid] else { continue }
            var perContainer: [AttachedFilesystem] = []
            for mount in mounts {
                let attached = try AttachedFilesystem(mount: mount, allocator: allocator)
                if mount.isBlock, let letter = attached.source.last {
                    bootDisks.append(.init(mount: mount, containerId: cid, letter: letter))
                }
                perContainer.append(attached)
            }
            attachments[cid] = perContainer
        }

        return (attachments, bootDisks)
    }
}
#endif
