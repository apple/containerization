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

#if os(macOS)

import ContainerizationError
import ContainerizationOCI
import Foundation

/// Manages single-file mounts by transforming them into virtiofs directory shares
/// plus bind mounts.
///
/// Since virtiofs only supports sharing directories, mounting a single file without
/// exposing the other potential files in that directory needs a little bit of a "hack".
/// The one we've landed on is:
///
/// 1. Creating a temporary directory containing a hardlink to the file
/// 2. Sharing that directory via virtiofs to a holding location in the guest
/// 3. Bind mounting the specific file from the holding location to the final destination
///
/// This type handles all three steps transparently.
struct FileMountContext: Sendable {
    /// Metadata for a single prepared file mount.
    struct PreparedMount: Sendable {
        /// Original file path on host
        let hostFilePath: String
        /// Where the user wants the file in the container
        let containerDestination: String
        /// Just the filename
        let filename: String
        /// Temp directory containing the hardlinked file
        let tempDirectory: URL
        /// The virtiofs tag (hash of temp dir path). Used to find the AttachedFilesystem
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
    /// a directory, it creates a temporary directory with a hardlink to the file and
    /// substitutes a directory share for the original mount.
    ///
    /// - Parameter mounts: The original mounts from the container config
    /// - Returns: A FileMountContext containing transformed mounts and tracking info
    static func prepare(mounts: [Mount]) throws -> FileMountContext {
        var context = FileMountContext()
        var transformed: [Mount] = []

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

            // Create a regular directory share for the temp directory.
            // The destination here is unused. We'll mount it ourselves to a location under /run.
            let directoryShare = Mount.share(
                source: prepared.tempDirectory.path,
                destination: "/.file-mount-holding",
                options: mount.options.filter { $0 != "bind" },
                runtimeOptions: runtimeOpts
            )
            transformed.append(directoryShare)
        }

        context.transformedMounts = transformed
        return context
    }

    private mutating func prepareFileMount(
        mount: Mount,
        runtimeOptions: [String]
    ) throws -> PreparedMount {
        let resolvedSource = URL(fileURLWithPath: mount.source).resolvingSymlinksInPath()
        let sourceURL = URL(fileURLWithPath: mount.source)
        let filename = sourceURL.lastPathComponent

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("containerization-file-mounts")
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        // Hardlink the file (falls back to copy if cross-filesystem)
        let destURL = tempDir.appendingPathComponent(filename)
        do {
            try FileManager.default.linkItem(at: resolvedSource, to: destURL)
        } catch {
            // Hardlink failed. Fall back to copy
            try FileManager.default.copyItem(at: resolvedSource, to: destURL)
        }

        let tag = try hashMountSource(source: tempDir.path)

        let prepared = PreparedMount(
            hostFilePath: mount.source,
            containerDestination: mount.destination,
            filename: filename,
            tempDirectory: tempDir,
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
        for i in preparedMounts.indices {
            let prepared = preparedMounts[i]

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

            let guestPath = "/run/file-mounts/\(prepared.tag)"
            try await agent.mkdir(path: guestPath, all: true, perms: 0o755)
            try await agent.mount(
                ContainerizationOCI.Mount(
                    type: "virtiofs",
                    source: attached.source,
                    destination: guestPath,
                    options: []
                ))

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

extension FileMountContext {
    /// Clean up temp directories.
    func cleanup() {
        let fm = FileManager.default
        for prepared in preparedMounts {
            try? fm.removeItem(at: prepared.tempDirectory)
        }
    }
}

#endif
