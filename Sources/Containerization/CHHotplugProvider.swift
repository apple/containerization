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
import Foundation
import Logging
import NIOHTTP1
import Synchronization

/// Hotplug provider for the cloud-hypervisor backend.
///
/// Handles both block (`vm.add-disk`) and virtiofs (`vm.add-fs`, with one
/// `virtiofsd` per unique source-hash tag) hotplug, plus the matching
/// `vm.remove-device` teardown. Owns the per-VM mount registry so
/// `CHVirtualMachineInstance.mounts` can forward to it.
final class CHHotplugProvider: HotplugProvider {
    struct HotplugRecord: Sendable {
        let chDeviceId: String
        let kind: Kind

        enum Kind: Sendable {
            case block(letter: Character)
            case virtiofs(tag: String)
        }
    }

    struct VirtiofsdTagState: Sendable {
        var process: VirtiofsdProcess
        var refcount: Int
        var chDeviceId: String
    }

    private let client: CloudHypervisor.Client
    private let workDir: URL
    private let virtiofsdBinaryOverride: URL?
    private let allocator: any AddressAllocator<Character>
    private let _mounts: Mutex<[String: [AttachedFilesystem]]>
    private let _records: Mutex<[String: [HotplugRecord]]>
    private let _tags: Mutex<[String: VirtiofsdTagState]>
    /// Serializes per-tag virtiofsd spawn so a concurrent hotplug for the
    /// same tag can't race the existence-check / process-registration window
    /// (TOCTOU → orphaned virtiofsd). Held across awaits, so it must be an
    /// `AsyncLock` rather than the sync `Mutex` that protects `_tags`.
    private let spawnLock: AsyncLock
    private let logger: Logger?

    init(
        client: CloudHypervisor.Client,
        workDir: URL,
        virtiofsdBinary: URL?,
        allocator: any AddressAllocator<Character>,
        initialMounts: [String: [AttachedFilesystem]],
        logger: Logger?
    ) {
        self.client = client
        self.workDir = workDir
        self.virtiofsdBinaryOverride = virtiofsdBinary
        self.allocator = allocator
        self._mounts = Mutex(initialMounts)
        self._records = Mutex([:])
        self._tags = Mutex([:])
        self.spawnLock = AsyncLock()
        self.logger = logger
    }

    // MARK: - Read accessors

    var mounts: [String: [AttachedFilesystem]] {
        _mounts.withLock { $0 }
    }

    func withMountRegistry<T: Sendable>(
        _ body: (inout sending [String: [AttachedFilesystem]]) throws -> sending T
    ) rethrows -> T {
        try _mounts.withLock(body)
    }

    // MARK: - HotplugProvider conformance

    func hotplug(_ rootfs: Mount, id: String) async throws -> AttachedFilesystem {
        switch rootfs.runtimeOptions {
        case .virtioblk:
            let letter = try allocator.allocate()
            let chId = "blk-\(id)-\(letter)"
            let disk = CloudHypervisor.DiskConfig(
                path: rootfs.source,
                readonly: rootfs.options.contains("ro"),
                id: chId,
                imageType: .raw
            )

            let pci: CloudHypervisor.PciDeviceInfo
            do {
                pci = try await chCall { try await self.client.vmAddDisk(disk) }
            } catch {
                try? allocator.release(letter)
                throw error
            }

            let attached = AttachedFilesystem(
                type: rootfs.type,
                source: "/dev/vd\(letter)",
                destination: rootfs.destination,
                options: rootfs.options
            )

            _records.withLock {
                $0[id, default: []].append(HotplugRecord(chDeviceId: pci.id, kind: .block(letter: letter)))
            }
            return attached

        case .virtiofs:
            // Compute the tag up front (throwing) so nothing can fail between
            // committing the virtiofsd/device and recording the HotplugRecord —
            // otherwise a thrown error would orphan a running virtiofsd.
            let tag = try hashFilePath(path: rootfs.source)
            let chDeviceId = try await ensureVirtiofsDevice(
                tag: tag,
                source: rootfs.source,
                readonly: rootfs.options.contains("ro")
            )
            _records.withLock {
                $0[id, default: []].append(HotplugRecord(chDeviceId: chDeviceId, kind: .virtiofs(tag: tag)))
            }
            return AttachedFilesystem(
                type: rootfs.type,
                source: tag,
                destination: rootfs.destination,
                options: rootfs.options
            )

        case .shared, .any:
            throw ContainerizationError(.unsupported, message: "hotplug rootfs must be virtio-blk or virtiofs")
        }
    }

    func registerMounts(id: String, rootfs: AttachedFilesystem, additionalMounts: [Mount]) throws {
        var attached: [AttachedFilesystem] = [rootfs]
        for mount in additionalMounts {
            attached.append(try AttachedFilesystem(mount: mount, allocator: allocator))
        }
        _mounts.withLock {
            $0[id, default: []].append(contentsOf: attached)
        }
    }

    func releaseHotplug(id: String) async throws {
        let popped: [HotplugRecord] = _records.withLock { records in
            let all = records[id] ?? []
            let blocks = all.filter { record in
                if case .block = record.kind { return true }
                return false
            }
            let remaining = all.filter { record in
                if case .block = record.kind { return false }
                return true
            }
            if remaining.isEmpty {
                records.removeValue(forKey: id)
            } else {
                records[id] = remaining
            }
            return blocks
        }

        for rec in popped {
            do {
                try await chCall { try await self.client.vmRemoveDevice(id: rec.chDeviceId) }
            } catch {
                logger?.warning("vmRemoveDevice failed for \(rec.chDeviceId): \(error)")
            }
            if case .block(let letter) = rec.kind {
                try? allocator.release(letter)
            }
        }

        // Drop block-derived AttachedFilesystem entries for `id`. Block entries
        // are the ones whose source was rewritten to "/dev/vd<letter>" by
        // `hotplug(_:)` (or by AttachedFilesystem(mount:allocator:) for an
        // additionalMount of type virtio-blk).
        _mounts.withLock { state in
            guard var perID = state[id] else { return }
            perID.removeAll { $0.source.hasPrefix("/dev/vd") }
            if perID.isEmpty {
                state.removeValue(forKey: id)
            } else {
                state[id] = perID
            }
        }
    }

    func hotplugVirtioFS(_ mounts: [Mount], id: String) async throws {
        let virtiofs = mounts.filter {
            if case .virtiofs = $0.runtimeOptions { return true }
            return false
        }
        guard !virtiofs.isEmpty else { return }

        // Group by tag (source-hash). Multiple Mounts to the same source dir
        // share a tag and a single virtiofsd.
        var byTag: [String: [Mount]] = [:]
        for mount in virtiofs {
            let tag = try hashFilePath(path: mount.source)
            byTag[tag, default: []].append(mount)
        }

        for (tag, group) in byTag {
            guard let source = group.first?.source else { continue }
            let readonly = group.allSatisfy { $0.options.contains("ro") }
            let chDeviceId = try await ensureVirtiofsDevice(tag: tag, source: source, readonly: readonly)
            // Record once per tag for this container. The AttachedFilesystem
            // entries for these mounts are written by registerMounts (the sole
            // _mounts writer), so we do NOT touch _mounts here.
            _records.withLock {
                $0[id, default: []].append(HotplugRecord(chDeviceId: chDeviceId, kind: .virtiofs(tag: tag)))
            }
        }
    }

    /// Ensure a virtio-fs device backed by `virtiofsd` exists for `tag`,
    /// spawning one (and issuing `vm.add-fs`) on first use or bumping the
    /// refcount of an existing one. Returns the cloud-hypervisor device id
    /// (`vm.remove-device` keys on it). Serialized per-provider by `spawnLock`
    /// so two concurrent callers for the same tag can't double-spawn.
    private func ensureVirtiofsDevice(tag: String, source: String, readonly: Bool) async throws -> String {
        try await spawnLock.withLock { _ in
            // Refcount-bump path: a virtiofsd already serves this tag.
            let cached: String? = self._tags.withLock { tags in
                if var state = tags[tag] {
                    state.refcount += 1
                    tags[tag] = state
                    return state.chDeviceId
                }
                return nil
            }
            if let cached {
                return cached
            }

            // First-spawn path: spawn → vm.add-fs → commit _tags, rolling back
            // the process/socket if vm.add-fs fails.
            let socket = chVirtiofsSocketURL(workDir: self.workDir, tag: tag)
            let virtiofsdBinary = try CHVirtualMachineManager.resolveBinary(
                self.virtiofsdBinaryOverride,
                name: "virtiofsd"
            )
            let process = VirtiofsdProcess(
                config: .init(
                    binary: virtiofsdBinary,
                    socketPath: socket,
                    sharedDir: URL(fileURLWithPath: source),
                    readonly: readonly
                ),
                logger: self.logger
            )

            try await process.start()

            let fsConfig = CloudHypervisor.FsConfig(
                tag: tag,
                socket: socket.path,
                id: "fs-\(tag)"
            )
            let pci: CloudHypervisor.PciDeviceInfo
            do {
                pci = try await chCall { try await self.client.vmAddFs(fsConfig) }
            } catch {
                await process.terminate(graceSeconds: 5)
                try? FileManager.default.removeItem(at: socket)
                throw error
            }

            self._tags.withLock {
                $0[tag] = VirtiofsdTagState(process: process, refcount: 1, chDeviceId: pci.id)
            }
            return pci.id
        }
    }

    func releaseVirtioFS(id: String) async throws {
        let popped: [HotplugRecord] = _records.withLock { records in
            let all = records[id] ?? []
            let fs = all.filter { record in
                if case .virtiofs = record.kind { return true }
                return false
            }
            let remaining = all.filter { record in
                if case .virtiofs = record.kind { return false }
                return true
            }
            if remaining.isEmpty {
                records.removeValue(forKey: id)
            } else {
                records[id] = remaining
            }
            return fs
        }

        var processesToStop: [(VirtiofsdProcess, String, String)] = []  // (process, tag, chDeviceId)
        for rec in popped {
            guard case .virtiofs(let tag) = rec.kind else { continue }
            _tags.withLock { tags in
                guard var state = tags[tag] else { return }
                state.refcount -= 1
                if state.refcount <= 0 {
                    tags.removeValue(forKey: tag)
                    processesToStop.append((state.process, tag, state.chDeviceId))
                } else {
                    tags[tag] = state
                }
            }
        }

        for (process, tag, chDeviceId) in processesToStop {
            do {
                try await chCall { try await self.client.vmRemoveDevice(id: chDeviceId) }
            } catch {
                logger?.warning("vmRemoveDevice failed for \(chDeviceId): \(error)")
            }
            await process.terminate(graceSeconds: 5)
            let socket = chVirtiofsSocketURL(workDir: workDir, tag: tag)
            try? FileManager.default.removeItem(at: socket)
        }

        // Drop virtiofs AttachedFilesystem entries for `id`. AttachedFilesystem
        // sets `type = mount.type` which for a `.virtiofs` mount is "virtiofs".
        _mounts.withLock { state in
            guard var perID = state[id] else { return }
            perID.removeAll { $0.type == "virtiofs" }
            if perID.isEmpty {
                state.removeValue(forKey: id)
            } else {
                state[id] = perID
            }
        }
    }

    // MARK: - Boot-time + shutdown hooks (used by CHVirtualMachineInstance)

    /// Record a virtiofsd that was started as part of `start()`'s initial
    /// `VmConfig.fs` (rather than a runtime `vm.add-fs`). The `chDeviceId`
    /// is the user-supplied `FsConfig.id` (which `vm.remove-device` keys on).
    /// `ownerIds` are the container ids that count toward this tag's refcount;
    /// each gets a `HotplugRecord` so `releaseVirtioFS(id:)` walks them
    /// uniformly.
    func recordBootTimeVirtiofs(
        tag: String,
        process: VirtiofsdProcess,
        chDeviceId: String,
        ownerIds: [String]
    ) {
        _tags.withLock {
            $0[tag] = VirtiofsdTagState(process: process, refcount: ownerIds.count, chDeviceId: chDeviceId)
        }
        _records.withLock { records in
            for id in ownerIds {
                records[id, default: []].append(HotplugRecord(chDeviceId: chDeviceId, kind: .virtiofs(tag: tag)))
            }
        }
    }

    /// Called from `CHVirtualMachineInstance.stop()` to terminate any
    /// virtiofsd subprocesses still alive. The CH side teardown is handled by
    /// `chProcess.terminate()`.
    func shutdown() async {
        let processes = _tags.withLock { tags -> [VirtiofsdProcess] in
            let all = tags.values.map(\.process)
            tags.removeAll()
            return all
        }
        _records.withLock { $0.removeAll() }

        for process in processes {
            await process.terminate(graceSeconds: 5)
        }
    }
}

// MARK: - Error translation

/// Wraps a closure that may throw `CloudHypervisor.Error`, translating it into
/// `ContainerizationError` per spec §6 so callers of the public API only see
/// `ContainerizationError`.
func chCall<T: Sendable>(_ block: @Sendable () async throws -> T) async throws -> T {
    do {
        return try await block()
    } catch let error as CloudHypervisor.Error {
        switch error {
        case .http(let status, let body):
            let bodyStr = String(data: body, encoding: .utf8) ?? "<non-utf8 body>"
            if status == .notFound {
                throw ContainerizationError(.notFound, message: "cloud-hypervisor 404: \(bodyStr)")
            }
            if status == .badRequest {
                throw ContainerizationError(.invalidArgument, message: "cloud-hypervisor 400: \(bodyStr)")
            }
            throw ContainerizationError(
                .internalError,
                message: "cloud-hypervisor HTTP \(status.code): \(bodyStr)"
            )
        case .transport(let underlying):
            throw ContainerizationError(.internalError, message: "cloud-hypervisor transport error", cause: underlying)
        case .decoding(let underlying, _):
            throw ContainerizationError(.internalError, message: "cloud-hypervisor response decode error", cause: underlying)
        case .invalidSocketPath(let path):
            throw ContainerizationError(.invalidArgument, message: "invalid cloud-hypervisor socket path: \(path)")
        }
    }
}
#endif
