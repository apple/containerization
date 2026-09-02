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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

extension Application {
    static func fetchImage(reference: String, store: ImageStore) async throws -> Containerization.Image {
        do {
            return try await store.get(reference: reference)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return try await store.pull(reference: reference)
            }
            throw error
        }
    }

    static func parseKeyValuePairs(from items: [String]) -> [String: String] {
        var parsedLabels: [String: String] = [:]
        for item in items {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = String(parts[0])
            let val = String(parts[1])
            parsedLabels[key] = val
        }
        return parsedLabels
    }

    /// Parse the ENTRYPOINT and CMD from an `ImageConfig` into the command to
    /// run: `ENTRYPOINT + (arguments ?? CMD)`.
    ///
    /// If arguments are present, they replace CMD and are appended to ENTRYPOINT
    ///
    /// - Throws: when the image declares neither and no command was given.
    static func resolveProcessArguments(
        arguments: [String],
        imageConfig: ImageConfig?,
        imageReference: String
    ) throws -> [String] {
        let entrypoint = imageConfig?.entrypoint ?? []
        let command = arguments.isEmpty ? (imageConfig?.cmd ?? []) : arguments
        let resolved = entrypoint + command
        guard !resolved.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "image \(imageReference) declares no entrypoint or cmd; pass a command to run"
            )
        }
        return resolved
    }
}

extension Containerization.Mount {
    /// `transform` for `cctl run --block`: parse a block-device specification
    /// into a virtio-block `Mount`.
    ///
    /// The value is a comma separated field list rather than the colon
    /// separated `host:guest` form used by `--mount`, because an NBD source is
    /// a URL which contains a colon (`nbd://host:10809`)
    ///
    /// Fields:
    /// - `src=<path|url>` (required): a host disk-image path, or an NBD URL
    ///   (`nbd://`, `nbds://`, `nbd+unix://`, `nbds+unix://`). NBD sources are
    ///   attachable on Apple Silicon only
    /// - `dst=<path>` (required): where the device is mounted in the container.
    /// - `fmt=<type>`: filesystem passed to `mount(2)` in the guest, default
    ///   `ext4`. Ignored when `raw` is set. It must already hold this filesystem
    ///   or the guest mount fails.
    /// - `timeout=<seconds>`: NBD connection timeout
    /// - `ro`: attach and mount read-only.
    /// - `raw`: bind mount the block device node itself rather than mounting a
    ///   filesystem from it, exposing the raw device to the workload.
    static func parseBlockArgument(_ spec: String) throws -> Containerization.Mount {
        var source: String?
        var destination: String?
        var format = "ext4"
        var readOnly = false
        var raw = false
        var runtimeOptions: [String] = []

        for field in spec.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = field.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count == 2 ? String(parts[1]) : nil

            switch (key, value) {
            case ("src", .some(let value)):
                source = value
            case ("dst", .some(let value)):
                destination = value
            case ("fmt", .some(let value)):
                format = value
            case ("timeout", .some(let value)):
                guard Double(value) != nil else {
                    throw ValidationError("--block timeout must be a number of seconds, got \"\(value)\"")
                }
                runtimeOptions.append("vzTimeout=\(value)")
            case ("ro", .none):
                readOnly = true
            case ("raw", .none):
                raw = true
            default:
                throw ValidationError("unknown --block field \"\(field)\" in \"\(spec)\"")
            }
        }

        guard let source, !source.isEmpty else {
            throw ValidationError("--block requires src=<path|url>, got \"\(spec)\"")
        }
        guard let destination, !destination.isEmpty else {
            throw ValidationError("--block requires dst=<path>, got \"\(spec)\"")
        }

        // A raw attachment bind mounts the device node, so file system type is meaningless
        var options: [String] = raw ? ["bind"] : []
        if readOnly {
            options.append("ro")
        }

        return .block(
            format: raw ? "none" : format,
            source: source,
            destination: destination,
            options: options,
            runtimeOptions: runtimeOptions
        )
    }
}

extension ContainerizationOCI.Platform {
    static var arm64: ContainerizationOCI.Platform {
        .init(arch: "arm64", os: "linux", variant: "v8")
    }
}
