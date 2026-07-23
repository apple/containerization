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

import AsyncHTTPClient
import ContainerizationError
import ContainerizationExtras
import Foundation
import NIO

extension RegistryClient {
    /// Pushes the content specified by a descriptor to a remote registry.
    /// - Parameters:
    ///    - name:          The namespace which the descriptor should belong under.
    ///    - tag:           The tag or digest for uniquely identifying the manifest.
    ///                     By convention, any portion that may be a partial or whole digest
    ///                     will be proceeded by an `@`. Anything preceding the `@` will be referred
    ///                     to as "tag".
    ///                     This is usually broken down into the following possibilities:
    ///                         1. <tag>
    ///                         2. <tag>@<digest>
    ///                         3. @<digest>
    ///                     The tag is anything except `@` and `:`, and digest is anything after the `@`
    ///    - descriptor:    The OCI descriptor of the content to be pushed.
    ///    - streamGenerator: A closure that produces an`AsyncStream` of `ByteBuffer`
    ///                     for streaming data to the `HTTPClientRequest.Body`.
    ///                     The caller is responsible for providing the `AsyncStream` where the data may come from
    ///                     a file on disk, data in memory, etc.
    ///    - progress: The progress handler to invoke as data is sent.
    public func push<T: Sendable & AsyncSequence>(
        name: String,
        ref tag: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        var components = base

        let mediaType = descriptor.mediaType
        if mediaType.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "missing media type for descriptor \(descriptor.digest)")
        }

        var isManifest = false
        var existCheck: [String] = []

        switch mediaType {
        case MediaTypes.dockerManifest, MediaTypes.dockerManifestList, MediaTypes.imageManifest, MediaTypes.index:
            isManifest = true
            existCheck = self.getManifestPath(tag: tag, digest: descriptor.digest)
        default:
            existCheck = ["blobs", descriptor.digest]
        }

        // Check if the content already exists.
        components.path = "/v2/\(name)/\(existCheck.joined(separator: "/"))"

        let mediaTypes = [
            mediaType,
            "*/*",
        ]

        var headers = [
            ("Accept", mediaTypes.joined(separator: ", "))
        ]

        try await request(components: components, method: .HEAD, headers: headers) { response in
            if response.status == .ok {
                var exists = false
                if isManifest && existCheck[1] != descriptor.digest {
                    if descriptor.digest == response.headers.first(name: "Docker-Content-Digest") {
                        exists = true
                    }
                } else {
                    exists = true
                }

                if exists {
                    throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)")
                }
            } else if response.status != .notFound {
                let url = components.url?.absoluteString ?? "unknown"
                let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                throw Error.invalidStatus(url: url, response.status, reason: reason)
            }
        }

        if isManifest {
            let path = self.getManifestPath(tag: tag, digest: descriptor.digest)
            components.path = "/v2/\(name)/\(path.joined(separator: "/"))"
            headers = [
                ("Content-Type", mediaType)
            ]
        } 

        // We have to pass a body closure rather than a body to reset the stream when retrying.
        let bodyClosure = {
            let stream = try streamGenerator()
            let body = HTTPClientRequest.Body.stream(stream, length: .known(descriptor.size))
            return body
        }

        // Establish our smart retry limits
        let maxRetries = self.retryOptions?.maxRetries ?? 3
        let retryInterval = self.retryOptions?.retryInterval ?? 1_000_000_000
        var retryCount = 0

        while true {
            do {
                if !isManifest {
                    // Start upload request for blobs to get a FRESH session URL.
                    var postComponents = base
                    postComponents.path = "/v2/\(name)/blobs/uploads/"
                    
                    // Override generic retry: we do NOT want the generic client retrying this POST
                    try await request(
                        components: postComponents, 
                        method: .POST,
                        retryOptionsOverride: RetryOptions(maxRetries: 0, retryInterval: 0)
                    ) { response in
                        switch response.status {
                        case .ok, .accepted, .noContent:
                            break
                        case .created:
                            throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)")
                        default:
                            let url = postComponents.url?.absoluteString ?? "unknown"
                            let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                            throw Error.invalidStatus(url: url, response.status, reason: reason)
                        }

                        guard let location = response.headers.first(name: "Location") else {
                            throw ContainerizationError(.invalidArgument, message: "missing required header Location")
                        }

                        guard let urlComponents = URLComponents(string: location) else {
                            throw ContainerizationError(.invalidArgument, message: "invalid url \(location)")
                        }
                        
                        var queryItems = urlComponents.queryItems ?? []
                        queryItems.append(URLQueryItem(name: "digest", value: descriptor.digest))
                        components.path = urlComponents.path
                        components.queryItems = queryItems
                        headers = [
                            ("Content-Type", "application/octet-stream"),
                            ("Content-Length", String(descriptor.size)),
                        ]
                    }
                }

                // Execute the PUT request with generic retries completely disabled
                try await request(
                    components: components, 
                    method: .PUT, 
                    bodyClosure: bodyClosure, 
                    headers: headers,
                    retryOptionsOverride: RetryOptions(maxRetries: 0, retryInterval: 0)
                ) { response in
                    switch response.status {
                    case .ok, .created, .noContent:
                        break
                    default:
                        let url = components.url?.absoluteString ?? "unknown"
                        let reason = await ErrorResponse.fromResponseBody(response.body)?.jsonString
                        throw Error.invalidStatus(url: url, response.status, reason: reason)
                    }

                    guard descriptor.digest == response.headers.first(name: "Docker-Content-Digest") else {
                        let required = response.headers.first(name: "Docker-Content-Digest") ?? ""
                        throw ContainerizationError(.internalError, message: "digest mismatch \(descriptor.digest) != \(required)")
                    }
                }
                
                // If the PUT succeeds without throwing, we break out of our smart retry loop
                break 
                
            } catch {
                // Intercept the failure. If we haven't hit our max retries, loop again to generate a new POST session.
                if retryCount < maxRetries {
                    retryCount += 1
                    try await Task.sleep(nanoseconds: retryInterval)
                    continue
                } else {
                    throw error
                }
            }
        }
    }

    private func getManifestPath(tag: String, digest: String) -> [String] {
        var object = tag
        if let i = tag.firstIndex(of: "@") {
            let index = tag.index(after: i)
            if String(tag[index...]) != digest {
                object = ""
            } else {
                object = String(tag[...i])
            }
        }

        if object == "" {
            return ["manifests", digest]
        }

        return ["manifests", object]
    }
}
