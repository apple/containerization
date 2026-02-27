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

import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

#if os(macOS)
import ContainerizationArchive
import ContainerizationEXT4
import SystemPackage
#endif

public struct EXT4Unpacker: Unpacker {
    let blockSizeInBytes: UInt64

    public init(blockSizeInBytes: UInt64) {
        self.blockSizeInBytes = blockSizeInBytes
    }

    #if os(macOS)
    /// Performs the unpacking of a tar archive into a filesystem.
    /// - Parameters:
    ///   - archive: The archive to unpack.
    ///   - compression: The compression to use when unpacking the image.
    ///   - path: The path to the filesystem that will be created.
    public func unpack(
        archive: URL,
        compression: ContainerizationArchive.Filter,
        at path: URL
    ) throws {
        let cleanedPath = try prepareUnpackPath(path: path)
        let filesystem = try EXT4.Formatter(
            FilePath(cleanedPath),
            minDiskSize: blockSizeInBytes
        )
        defer { try? filesystem.close() }

        try filesystem.unpack(
            source: archive,
            format: .paxRestricted,
            compression: compression,
            progress: nil
        )
    }
    #endif

    /// Returns a `Mount` point after unpacking the image into a filesystem.
    /// - Parameters:
    ///   - image: The image to unpack.
    ///   - platform: The platform content to unpack.
    ///   - path: The path to the directory where the filesystem will be created.
    ///   - progress: The progress handler to invoke as the unpacking progresses.
    public func unpack(
        _ image: Image,
        for platform: Platform,
        at path: URL,
        progress: ProgressHandler? = nil
    ) async throws -> Mount {
        #if !os(macOS)
        throw ContainerizationError(.unsupported, message: "cannot unpack an image on current platform")
        #else
        let cleanedPath = try prepareUnpackPath(path: path)
        let manifest = try await image.manifest(for: platform)
        let filesystem = try EXT4.Formatter(
            FilePath(
                cleanedPath
            ),
            minDiskSize: blockSizeInBytes
        )
        defer { try? filesystem.close() }

        if let progress {
            let totalSize = try await totalRegularFileBytes(in: manifest.layers, image: image)
            if totalSize > 0 {
                await progress([ProgressEvent(event: "add-total-size", value: totalSize)])
            }
        }

        for layer in manifest.layers {
            try Task.checkCancellation()
            let content = try await image.getContent(digest: layer.digest)

            let compression = try compressionFilter(for: layer.mediaType)
            let reader = try ArchiveReader(
                format: .paxRestricted,
                filter: compression,
                file: content.path
            )
            try filesystem.unpack(reader: reader, progress: progress)
        }

        return .block(
            format: "ext4",
            source: cleanedPath,
            destination: "/",
            options: []
        )
        #endif
    }

    private func prepareUnpackPath(path: URL) throws -> String {
        let blockPath = path.absolutePath()
        guard !FileManager.default.fileExists(atPath: blockPath) else {
            throw ContainerizationError(.exists, message: "block device already exists at \(blockPath)")
        }
        return blockPath
    }

    #if os(macOS)
    private func compressionFilter(for mediaType: String) throws -> ContainerizationArchive.Filter {
        switch mediaType {
        case MediaTypes.imageLayer, MediaTypes.dockerImageLayer:
            return .none
        case MediaTypes.imageLayerGzip, MediaTypes.dockerImageLayerGzip:
            return .gzip
        case MediaTypes.imageLayerZstd, MediaTypes.dockerImageLayerZstd:
            return .zstd
        default:
            throw ContainerizationError(.unsupported, message: "media type \(mediaType) not supported.")
        }
    }

    private func totalRegularFileBytes(in layers: [Descriptor], image: Image) async throws -> Int64 {
        var totalSize: Int64 = 0

        for layer in layers {
            try Task.checkCancellation()

            let compression = try compressionFilter(for: layer.mediaType)
            let content = try await image.getContent(digest: layer.digest)
            let reader = try ArchiveReader(
                format: .paxRestricted,
                filter: compression,
                file: content.path
            )

            for (entry, _) in reader.makeStreamingIterator() {
                try Task.checkCancellation()
                guard entry.fileType == .regular, let size = entry.size else {
                    continue
                }

                let fileSize = Int64(clamping: size)
                if totalSize > Int64.max - fileSize {
                    return Int64.max
                }
                totalSize += fileSize
            }
        }

        return totalSize
    }
    #endif
}
