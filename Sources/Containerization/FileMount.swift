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

import ContainerizationError
import ContainerizationOCI
import Foundation

/// Manages single-file mounts by transforming them into virtiofs directory shares
/// plus bind mounts.
///
/// Since virtiofs only supports sharing directories, mounting a single file requires
/// sharing the file's parent directory via virtiofs and then bind mounting the specific
/// file from that share to the final destination in the container.
struct FileMountContext: Sendable {
    /// Metadata for a single prepared file mount.
    struct PreparedMount: Sendable {
        /// Original file path on host
        let hostFilePath: String
        /// Where the user wants the file in the container
        let containerDestination: String
        /// Just the filename (after resolving symlinks)
        let filename: String
        /// The parent directory containing the file (after resolving symlinks)
        let parentDirectory: URL
        /// The virtiofs tag (hash of parent dir path). Used to find the AttachedFilesystem
        let tag: String
        /// Mount options from the original mount
        let options: [String]
        /// Where we mounted the share in the guest (set after mountHoldingDirectories)
        var guestHoldingPath: String?
    }

    /// Prepared file mounts for this context
    var preparedMounts: [PreparedMount]

    /// The transformed mounts to pass to the VM (files replaced with directory shares)
    private(set) var transformedMounts: [Mount]

    private init() {
        self.preparedMounts = []
        self.transformedMounts = []
    }

    /// Returns true if there are any file mounts that need handling.
    var hasFileMounts: Bool {
        !preparedMounts.isEmpty
    }

    /// Returns the set of virtiofs tags for file mount holding directories.
    /// These should be filtered out from OCI spec mounts since we mount them
    /// separately under /run.
    var holdingDirectoryTags: Set<String> {
        Set(preparedMounts.map { $0.tag })
    }
}

extension FileMountContext {
    /// Prepare mounts for a container, detecting file mounts and transforming them.
    ///
    /// This method stats each virtiofs mount source. If it's a regular file rather than
    /// a directory, it shares the file's parent directory via virtiofs and records the
    /// metadata needed to bind mount the specific file later.
    ///
    /// - Parameter mounts: The original mounts from the container config
    /// - Returns: A FileMountContext containing transformed mounts and tracking info
    static func prepare(mounts: [Mount]) throws -> FileMountContext {
        var context = FileMountContext()
        var transformed: [Mount] = []
        // Track parent directories we've already added a share for to avoid duplicates.
        var sharedParentTags: Set<String> = []

        for mount in mounts {
            // Only virtiofs mounts can be files
            guard case .virtiofs(let runtimeOpts) = mount.runtimeOptions else {
                transformed.append(mount)
                continue
            }

            // Stat the source to see if it's a file
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: mount.source, isDirectory: &isDirectory) else {
                // Doesn't exist. Let the normal flow handle the error
                transformed.append(mount)
                continue
            }

            if isDirectory.boolValue {
                // It's a directory, pass through unchanged
                transformed.append(mount)
                continue
            }

            // It's a file, so prepare it.
            let prepared = try context.prepareFileMount(mount: mount, runtimeOptions: runtimeOpts)

            // Only add the directory share once per unique parent directory.
            if !sharedParentTags.contains(prepared.tag) {
                sharedParentTags.insert(prepared.tag)
                // The destination here is unused. We mount the share ourselves
                // to a location under /run in mountHoldingDirectories.
                let directoryShare = Mount.share(
                    source: prepared.parentDirectory.path,
                    destination: "/.file-mount-holding",
                    options: mount.options.filter { $0 != "bind" },
                    runtimeOptions: runtimeOpts
                )
                transformed.append(directoryShare)
            }
        }

        context.transformedMounts = transformed
        return context
    }

    private mutating func prepareFileMount(
        mount: Mount,
        runtimeOptions: [String]
    ) throws -> PreparedMount {
        let resolvedSource = URL(fileURLWithPath: mount.source).resolvingSymlinksInPath()
        let filename = resolvedSource.lastPathComponent
        let parentDirectory = resolvedSource.deletingLastPathComponent()
        let tag = try hashMountSource(source: parentDirectory.path)

        let prepared = PreparedMount(
            hostFilePath: mount.source,
            containerDestination: mount.destination,
            filename: filename,
            parentDirectory: parentDirectory,
            tag: tag,
            options: mount.options,
            guestHoldingPath: nil
        )

        preparedMounts.append(prepared)
        return prepared
    }
}

extension FileMountContext {
    /// Mount the holding directories in the guest for all file mounts.
    /// - Parameters:
    ///   - vmMounts: The AttachedFilesystem array from the VM for this container
    ///   - agent: The VM agent for RPCs
    mutating func mountHoldingDirectories(
        vmMounts: [AttachedFilesystem],
        agent: any VirtualMachineAgent
    ) async throws {
        // Track which tags we've already mounted to avoid duplicate mounts
        // when multiple files share the same parent directory.
        var mountedTags: Set<String> = []

        for i in preparedMounts.indices {
            let prepared = preparedMounts[i]

            let guestPath = "/run/file-mounts/\(prepared.tag)"

            if !mountedTags.contains(prepared.tag) {
                // Find the attached filesystem by matching the virtiofs tag
                guard
                    let attached = vmMounts.first(where: {
                        $0.type == "virtiofs" && $0.source == prepared.tag
                    })
                else {
                    throw ContainerizationError(
                        .notFound,
                        message: "could not find attached filesystem for file mount \(prepared.hostFilePath)"
                    )
                }

                try await agent.mkdir(path: guestPath, all: true, perms: 0o755)
                try await agent.mount(
                    ContainerizationOCI.Mount(
                        type: "virtiofs",
                        source: attached.source,
                        destination: guestPath,
                        options: []
                    ))

                mountedTags.insert(prepared.tag)
            }

            preparedMounts[i].guestHoldingPath = guestPath
        }
    }
}

extension FileMountContext {
    /// Get the bind mounts to append to the OCI spec.
    func ociBindMounts() -> [ContainerizationOCI.Mount] {
        preparedMounts.compactMap { prepared in
            guard let guestPath = prepared.guestHoldingPath else {
                return nil
            }

            return ContainerizationOCI.Mount(
                type: "none",
                source: "\(guestPath)/\(prepared.filename)",
                destination: prepared.containerDestination,
                options: ["bind"] + prepared.options
            )
        }
    }
}
