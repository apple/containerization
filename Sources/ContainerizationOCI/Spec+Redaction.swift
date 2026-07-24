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

extension Spec {
    /// Returns a copy of the spec that is safe to include in log output:
    /// the environment variable values of the container process and of all
    /// lifecycle hooks are replaced with `<redacted>`, keeping only the
    /// variable names. Environment variables routinely carry secrets, and
    /// logs must not expose them.
    public func redactingEnvironmentValues() -> Spec {
        var copy = self
        copy.process = copy.process?.redactingEnvironmentValues()
        copy.hooks = copy.hooks?.redactingEnvironmentValues()
        return copy
    }
}

extension Process {
    /// Returns a copy of the process whose environment variable values are
    /// replaced with `<redacted>`, keeping only the variable names. Use this
    /// when rendering a process into log output so secrets injected through
    /// the environment are not exposed.
    public func redactingEnvironmentValues() -> Process {
        var copy = self
        copy.env = redactedEnvironment(copy.env)
        return copy
    }
}

extension Hook {
    /// Returns a copy of the hook whose environment variable values are
    /// replaced with `<redacted>`, keeping only the variable names.
    public func redactingEnvironmentValues() -> Hook {
        var copy = self
        copy.env = redactedEnvironment(copy.env)
        return copy
    }
}

extension Hooks {
    /// Returns a copy of the hooks whose environment variable values are
    /// replaced with `<redacted>`, keeping only the variable names.
    public func redactingEnvironmentValues() -> Hooks {
        var copy = self
        copy.prestart = copy.prestart.map { $0.redactingEnvironmentValues() }
        copy.createRuntime = copy.createRuntime.map { $0.redactingEnvironmentValues() }
        copy.createContainer = copy.createContainer.map { $0.redactingEnvironmentValues() }
        copy.startContainer = copy.startContainer.map { $0.redactingEnvironmentValues() }
        copy.poststart = copy.poststart.map { $0.redactingEnvironmentValues() }
        copy.poststop = copy.poststop.map { $0.redactingEnvironmentValues() }
        return copy
    }
}

/// Replaces the value of every `NAME=value` entry with `<redacted>`. Entries
/// without an `=` are kept as-is: they name variables to inherit and carry
/// no value of their own.
private func redactedEnvironment(_ env: [String]) -> [String] {
    env.map { entry in
        guard let separator = entry.firstIndex(of: "=") else {
            return entry
        }
        return entry[..<separator] + "=<redacted>"
    }
}
