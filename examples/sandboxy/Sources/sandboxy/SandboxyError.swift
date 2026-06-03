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

import Foundation

enum SandboxyError: Error, CustomStringConvertible {
    case configFailedToLoad(error: Swift.Error)
    case installFailed(step: Int, command: String, exitCode: Int32)
    case kernelDownloadFailed(reason: String)
    case proxyFailed(reason: String)
    case kernelNotFound(path: String)
    case incompleteAgentDefinition(missing: [String])
    case invalidMountSpec(spec: String)
    case envVarNotSet(name: String)

    var description: String {
        switch self {
        case .configFailedToLoad(let error):
            return "Failed to load sandbox config: \(error)"
        case .installFailed(let step, let command, let exitCode):
            return """
                Installation step \(step) failed (exit code \(exitCode)).
                Command: \(command)
                """
        case .kernelDownloadFailed(let reason):
            return "Failed to download kernel: \(reason)"
        case .proxyFailed(let reason):
            return "Proxy failed: \(reason)"
        case .kernelNotFound(let path):
            return "Kernel not found at \(path). Provide a valid path with -k or omit to auto-download."
        case .incompleteAgentDefinition(let missing):
            return "Agent definition is missing required fields: \(missing.joined(separator: ", ")). Use 'sandboxy config --agent claude' to see a complete example."
        case .invalidMountSpec(let spec):
            return "Invalid mount specification: '\(spec)'. Expected format: hostpath:containerpath[:ro|rw]"
        case .envVarNotSet(let name):
            return "Environment variable '\(name)' is not set on the host."
        }
    }
}
