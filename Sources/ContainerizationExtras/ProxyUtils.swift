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
import Foundation

/// A small utility to resolve proxy settings (HTTP(S)_PROXY / NO_PROXY).
public enum ProxyUtils {
    /// Resolves the proxy URL for a given host based on environment variables.
    /// Malformed http_proxy or https_proxy URLs are ignored.
    /// Uses Go-style handling rules:
    ///   - Uppercase environment variables take priority over lowercase counterparts.
    ///   - Leading dot on no_proxy component implies prefix matching.
    ///
    /// - Parameters:
    ///   - scheme: The request scheme.
    ///   - host: The request hostname.
    ///   - env: Environment variables to check, dafaulting to the process environment.
    ///
    /// - Returns: The proxy URL to use, or `nil` for transparent connection.
    public static func proxyFromEnvironment(
        scheme: String?,
        host: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let scheme else {
            return nil
        }

        let httpProxy = env["HTTP_PROXY"] ?? env["http_proxy"]
        let httpsProxy = env["HTTPS_PROXY"] ?? env["https_proxy"]
        let noProxy = env["NO_PROXY"] ?? env["no_proxy"]

        // If NO_PROXY matches → skip proxy
        if let noProxy, shouldBypassProxy(host: host, noProxy: noProxy) {
            return nil
        }

        // Select proxy based on scheme, defaulting to http.
        let proxy = scheme == "https" ? httpsProxy : httpProxy
        guard let proxy, let proxyUrl = URL(string: proxy) else {
            return nil
        }

        return proxyUrl
    }

    /// Check if a host should bypass proxy according to NO_PROXY.
    /// - Example: NO_PROXY=".example.com,localhost,127.0.0.1"
    private static func shouldBypassProxy(host: String, noProxy: String) -> Bool {
        let entries = noProxy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for entry in entries {
            if entry.isEmpty { continue }
            if entry == "*" { return true }
            if host == entry { return true }
            if entry.hasPrefix(".") && host.hasSuffix(entry) { return true }
        }
        return false
    }
}
