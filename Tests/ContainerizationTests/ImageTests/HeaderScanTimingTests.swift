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

#if os(macOS)
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import Containerization

/// Measures header scan overhead vs. full unpack time using real container images
/// pulled from a registry.
///
/// Run with:
///   ENABLE_TIMING_TESTS=1 swift test --filter ImageHeaderScanTimingTest
@Suite
struct ImageHeaderScanTimingTest {
    private static let isEnabled = ProcessInfo.processInfo.environment["ENABLE_TIMING_TESTS"] != nil

    let store: ImageStore
    let dir: URL
    let contentStore: ContentStore

    init() throws {
        let dir = FileManager.default.uniqueTemporaryDirectory(create: true)
        let cs = try LocalContentStore(path: dir)
        let store = try ImageStore(path: dir, contentStore: cs)
        self.dir = dir
        self.store = store
        self.contentStore = cs
    }

    @Test(.enabled(if: ImageHeaderScanTimingTest.isEnabled))
    func measureAlpineAndUbuntu() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }

        let images: [(reference: String, label: String)] = [
            ("ghcr.io/linuxcontainers/alpine:3.20", "Alpine 3.20"),
            ("docker.io/library/ubuntu:24.04", "Ubuntu 24.04"),
        ]

        for image in images {
            print("\n==============================")
            print("Image: \(image.label)")
            print("==============================")

            let img = try await store.pull(reference: image.reference, platform: .current)
            let manifest = try await img.manifest(for: .current)

            for (i, layer) in manifest.layers.enumerated() {
                let content = try await img.getContent(digest: layer.digest)
                let compression = compressionFilter(for: layer.mediaType)
                let compressedSize = try FileManager.default.attributesOfItem(atPath: content.path.path)[.size] as? Int64 ?? 0
                let label = "\(image.label) layer \(i + 1)/\(manifest.layers.count) (\(layer.mediaType), \(formatBytes(compressedSize)) compressed)"
                try measureOverhead(url: content.path, compression: compression, label: label)
            }
        }
    }

    // MARK: - Helpers

    private func compressionFilter(for mediaType: String) -> ContainerizationArchive.Filter {
        switch mediaType {
        case MediaTypes.imageLayerZstd, MediaTypes.dockerImageLayerZstd:
            return .zstd
        case MediaTypes.imageLayer, MediaTypes.dockerImageLayer:
            return .none
        default:
            return .gzip
        }
    }

    private func measureOverhead(url: URL, compression: ContainerizationArchive.Filter, label: String) throws {
        let clock = ContinuousClock()

        print("\n--- \(label) ---\n")

        // For zstd, pre-decompress once (matching the production code path in EXT4Unpacker).
        let scanFile: URL
        let scanFilter: ContainerizationArchive.Filter
        var decompressedFile: URL?
        if compression == .zstd {
            var decompressed: URL!
            let decompressDuration = try clock.measure {
                decompressed = try ArchiveReader.decompressZstd(url)
            }
            scanFile = decompressed
            scanFilter = .none
            decompressedFile = decompressed
            print("  Zstd decompress:      \(decompressDuration)")
        } else {
            scanFile = url
            scanFilter = compression
        }
        defer {
            if let decompressedFile {
                ArchiveReader.cleanUpDecompressedZstd(decompressedFile)
            }
        }

        // 1. Header scan only
        let scanDuration = try clock.measure {
            let reader = try ArchiveReader(format: .paxRestricted, filter: scanFilter, file: scanFile)
            var totalSize: Int64 = 0
            for (entry, _) in reader.makeStreamingIterator() {
                if entry.fileType == .regular, let size = entry.size {
                    totalSize += Int64(size)
                }
            }
            print("  Scanned total size:   \(formatBytes(totalSize))")
        }
        print("  Header scan:          \(scanDuration)")

        // 2. Full unpack without progress
        let tempDir1 = FileManager.default.uniqueTemporaryDirectory()
        let fsPath1 = FilePath(tempDir1.appendingPathComponent("no-progress.ext4.img", isDirectory: false))
        defer { try? FileManager.default.removeItem(at: tempDir1) }

        let unpackOnlyDuration = try clock.measure {
            let formatter = try EXT4.Formatter(fsPath1)
            try formatter.unpack(source: url, compression: compression)
            try formatter.close()
        }
        print("  Unpack (no progress): \(unpackOnlyDuration)")

        // 3. Full unpack with progress (includes header scan pass)
        let tempDir2 = FileManager.default.uniqueTemporaryDirectory()
        let fsPath2 = FilePath(tempDir2.appendingPathComponent("with-progress.ext4.img", isDirectory: false))
        defer { try? FileManager.default.removeItem(at: tempDir2) }

        let noopProgress: ProgressHandler = { _ in }
        let withProgressDuration = try clock.measure {
            let formatter = try EXT4.Formatter(fsPath2)
            try formatter.unpack(source: url, compression: compression, progress: noopProgress)
            try formatter.close()
        }
        print("  Unpack (w/ progress): \(withProgressDuration)")

        // Summary
        let scanMs = toMs(scanDuration)
        let unpackMs = toMs(unpackOnlyDuration)
        let withProgressMs = toMs(withProgressDuration)
        let overheadMs = withProgressMs - unpackMs
        let overheadPct = unpackMs > 0 ? (overheadMs / unpackMs) * 100 : 0

        print("\n  Summary:")
        print("    Header scan alone:  \(String(format: "%.1f", scanMs)) ms")
        print("    Unpack only:        \(String(format: "%.1f", unpackMs)) ms")
        print("    Unpack + progress:  \(String(format: "%.1f", withProgressMs)) ms")
        print("    Overhead:           \(String(format: "%.1f", overheadMs)) ms (\(String(format: "%.1f", overheadPct))%)")
    }

    private func toMs(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1e15
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return "\(String(format: "%.1f", mb)) MB"
    }
}
#endif
