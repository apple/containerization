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

/// A container's storage, by role.
///
/// The same shape describes storage at both stages of its life: as the
/// `Mount` values a container is configured with, and as the
/// `AttachedFilesystem` values the machine reports once they are attached.
/// Converting between the two is a `map` over the structure, so the roles
/// cannot drift apart between configuration and attachment.
public struct ContainerStorage<Value: Sendable>: Sendable {
    /// The container's root filesystem.
    public var rootfs: Value

    /// The writable layer mounted over the rootfs as the upper side of an
    /// overlay, when the container has one.
    public var writableLayer: Value?

    /// The swap area enabled for the container, when it has one.
    public var swap: Value?

    /// The container's remaining mounts, in configuration order.
    public var mounts: [Value]

    public init(rootfs: Value, writableLayer: Value? = nil, swap: Value? = nil, mounts: [Value] = []) {
        self.rootfs = rootfs
        self.writableLayer = writableLayer
        self.swap = swap
        self.mounts = mounts
    }

    /// Every value in the structure: the rootfs, the writable layer and swap
    /// when present, then the mounts, in that order.
    public var all: [Value] {
        var values = [rootfs]
        if let writableLayer {
            values.append(writableLayer)
        }
        if let swap {
            values.append(swap)
        }
        values.append(contentsOf: mounts)
        return values
    }

    /// The storage with `transform` applied to every value, each keeping
    /// its role.
    public func map<U: Sendable>(_ transform: (Value) throws -> U) rethrows -> ContainerStorage<U> {
        ContainerStorage<U>(
            rootfs: try transform(rootfs),
            writableLayer: try writableLayer.map(transform),
            swap: try swap.map(transform),
            mounts: try mounts.map(transform)
        )
    }
}

/// A container's storage as configured, before its machine exists.
public typealias ContainerMounts = ContainerStorage<Mount>

/// A container's storage as attached to its machine.
public typealias ContainerAttachments = ContainerStorage<AttachedFilesystem>

/// The storage a machine carries: each container's, and the resources its
/// containers share.
public struct MachineStorage<Value: Sendable>: Sendable {
    /// Each container's storage, by container ID.
    public var containers: [String: ContainerStorage<Value>]

    /// Volumes shared by the machine's containers, by volume name.
    public var volumes: [String: Value]

    public init(containers: [String: ContainerStorage<Value>] = [:], volumes: [String: Value] = [:]) {
        self.containers = containers
        self.volumes = volumes
    }

    /// Every value the machine carries: containers sorted by ID, each in
    /// role order, then volumes sorted by name. Walks that allocate device
    /// addresses and walks that create the devices use this one order, so an
    /// address always names the device it was handed out for.
    public var ordered: [Value] {
        containers.keys.sorted().flatMap { containers[$0]?.all ?? [] }
            + volumes.keys.sorted().compactMap { volumes[$0] }
    }

    /// The storage with `transform` applied to every value, each keeping its
    /// place. The transform runs in no particular order, so an allocating
    /// conversion walks the fields sorted itself.
    public func map<U: Sendable>(_ transform: (Value) throws -> U) rethrows -> MachineStorage<U> {
        MachineStorage<U>(
            containers: try containers.mapValues { try $0.map(transform) },
            volumes: try volumes.mapValues(transform)
        )
    }
}

/// A machine's storage as configured, before it exists.
public typealias MachineMounts = MachineStorage<Mount>

/// A machine's storage as attached.
public typealias MachineAttachments = MachineStorage<AttachedFilesystem>
