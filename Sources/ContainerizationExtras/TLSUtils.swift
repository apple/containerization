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

import Foundation
import NIO
import NIOSSL

public enum TLSUtils {

    public static func makeEnvironmentAwareTLSConfiguration() -> TLSConfiguration {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()

        // Check standard SSL environment variables in priority order
        let customCAPath =
            ProcessInfo.processInfo.environment["SSL_CERT_FILE"]
            ?? ProcessInfo.processInfo.environment["CURL_CA_BUNDLE"]
            ?? ProcessInfo.processInfo.environment["REQUESTS_CA_BUNDLE"]

        if let caPath = customCAPath {
            tlsConfig.trustRoots = .file(caPath)
        }
        // else: use .default

        return tlsConfig
    }
}
