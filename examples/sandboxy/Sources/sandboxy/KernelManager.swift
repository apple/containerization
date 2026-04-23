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

import AsyncHTTPClient
import ContainerizationArchive
import ContainerizationExtras
import Foundation

enum KernelManager {
    // Hardcoded default kernel source (Kata Containers arm64 static release).
    private static let defaultKernelURL =
        "https://github.com/kata-containers/kata-containers/releases/download/3.26.0/kata-static-3.26.0-arm64.tar.zst"
    private static let defaultKernelPathInTarball = "opt/kata/share/kata-containers/vmlinux.container"

    /// Ensures a kernel binary is available, returning its path.
    ///
    /// Resolution order:
    /// 1. CLI flag (`-k` / `--kernel`)
    /// 2. Config file (`"kernel"` field)
    /// 3. Cached kernel at `appRoot/kernel/vmlinux`
    /// 4. Auto-download from Kata Containers
    static func ensureKernel(explicitPath: String?, appRoot: URL, config: SandboxyConfig) async throws -> URL {
        // 1. CLI flag takes priority.
        if let explicitPath {
            let url = URL(fileURLWithPath: explicitPath)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw SandboxyError.kernelNotFound(path: explicitPath)
            }
            return url
        }

        // 2. Config file path.
        if let configKernel = config.kernel {
            let url = URL(fileURLWithPath: configKernel)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw SandboxyError.kernelNotFound(path: configKernel)
            }
            return url
        }

        // 3. Cached kernel.
        let kernelDir = appRoot.appendingPathComponent("kernel")
        let kernelPath = kernelDir.appendingPathComponent("vmlinux")

        if FileManager.default.fileExists(atPath: kernelPath.path(percentEncoded: false)) {
            return kernelPath
        }

        // 4. Auto-download.
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)

        let progressConfig = try ProgressConfig(
            description: "Downloading kernel",
            showTasks: true,
            totalTasks: 2
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        let tarballPath = kernelDir.appendingPathComponent("kata.tar.zst")
        try await downloadFile(from: defaultKernelURL, to: tarballPath, progress: progress)

        progress.set(description: "Extracting kernel")
        try extractKernel(from: tarballPath, kernelPathInTarball: defaultKernelPathInTarball, to: kernelPath)

        try FileManager.default.removeItem(at: tarballPath)

        return kernelPath
    }

    private static func downloadFile(from urlString: String, to destination: URL, progress: ProgressBar) async throws {
        guard let url = URL(string: urlString) else {
            throw SandboxyError.kernelDownloadFailed(reason: "invalid URL: \(urlString)")
        }

        let delegate = try FileDownloadDelegate(
            path: destination.path(percentEncoded: false),
            reportHead: { head in
                if let contentLength = head.headers["Content-Length"].first, let totalBytes = Int64(contentLength) {
                    progress.add(totalSize: totalBytes)
                }
            },
            reportProgress: { progressUpdate in
                progress.set(size: Int64(progressUpdate.receivedBytes))
            }
        )

        let request = try HTTPClient.Request(url: url)
        let client = createClient(url: url)
        do {
            _ = try await client.execute(request: request, delegate: delegate).get()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    private static func createClient(url: URL) -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        httpConfiguration.timeout = HTTPClient.Configuration.Timeout(
            connect: .seconds(30),
            read: .none
        )
        if let host = url.host {
            let proxyURL = ProxyUtils.proxyFromEnvironment(scheme: url.scheme, host: host)
            if let proxyURL, let proxyHost = proxyURL.host {
                httpConfiguration.proxy = HTTPClient.Configuration.Proxy.server(host: proxyHost, port: proxyURL.port ?? 8080)
            }
        }

        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }

    private static func extractKernel(from tarball: URL, kernelPathInTarball: String, to destination: URL) throws {
        var target = kernelPathInTarball
        var reader = try ArchiveReader(file: tarball)
        var (entry, data) = try reader.extractFile(path: target)

        // If the target file is a symlink, get the data for the actual file.
        if entry.fileType == .symbolicLink, let symlinkRelative = entry.symlinkTarget {
            reader = try ArchiveReader(file: tarball)
            let symlinkTarget = URL(filePath: target).deletingLastPathComponent().appending(path: symlinkRelative)

            // Standardize so that we remove any and all ../ and ./ in the path since symlink targets
            // are relative paths to the target file from the symlink's parent dir itself.
            target = symlinkTarget.standardized.relativePath
            let (_, targetData) = try reader.extractFile(path: target)
            data = targetData
        }

        try data.write(to: destination, options: .atomic)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path(percentEncoded: false)
        )
    }
}
