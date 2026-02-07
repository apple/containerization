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

import ContainerizationOCI

/// Redacts environment variable values from a list of env vars in "KEY=VALUE" format.
/// Returns the env vars with values replaced by "<redacted>".
func redactEnvValues(_ env: [String]) -> [String] {
    env.map { entry in
        if let equalsIndex = entry.firstIndex(of: "=") {
            let key = entry[..<equalsIndex]
            return "\(key)=<redacted>"
        }
        return entry
    }
}

/// A log-safe representation of a Process that redacts environment variable values.
struct RedactedProcess: CustomStringConvertible {
    let process: ContainerizationOCI.Process

    var description: String {
        var copy = process
        copy.env = redactEnvValues(copy.env)
        return "\(copy)"
    }
}

/// A log-safe representation of a Spec that redacts environment variable values.
struct RedactedSpec: CustomStringConvertible {
    let spec: ContainerizationOCI.Spec

    var description: String {
        var copy = spec
        if var process = copy.process {
            process.env = redactEnvValues(process.env)
            copy.process = process
        }
        return "\(copy)"
    }
}

extension ContainerizationOCI.Spec {
    var redacted: RedactedSpec {
        RedactedSpec(spec: self)
    }
}

extension ContainerizationOCI.Process {
    var redacted: RedactedProcess {
        RedactedProcess(process: self)
    }
}
