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

// Environment variables routinely carry secrets, so rendering a process or a
// hook as text must not expose their values. These conformances make the
// redacted form the *default* rendering rather than something a caller has to
// opt into: any `\(spec)` or `\(process)`, in this repo or downstream, is safe
// without the author knowing this file exists.
//
// Only the two types that own an `env` need conforming. Swift's reflection
// based description uses a nested value's own `description`, so `Spec` and
// `Hooks` inherit the redaction through the values they hold.
//
// This affects text rendering only. `Codable` is untouched, so an encoded spec
// still carries the real values, and the unredacted environment remains
// available to callers through `process.env`.

extension Process: CustomStringConvertible {
    public var description: String {
        var copy = self
        copy.env = redactingEnvironmentValues(copy.env)
        return describeFields(of: copy)
    }
}

extension Hook: CustomStringConvertible {
    public var description: String {
        var copy = self
        copy.env = redactingEnvironmentValues(copy.env)
        return describeFields(of: copy)
    }
}

/// Replaces the value of every `NAME=value` entry with `<redacted>`, keeping
/// the name, which is still useful for seeing *which* variables were set.
/// Entries without an `=` are kept as-is: they name a variable to inherit and
/// carry no value of their own.
private func redactingEnvironmentValues(_ env: [String]) -> [String] {
    env.map { entry in
        guard let separator = entry.firstIndex(of: "=") else {
            return entry
        }
        return entry[..<separator] + "=<redacted>"
    }
}

/// Renders `TypeName(label: value, ...)`, the shape Swift's own description
/// produces. Going through a mirror rather than listing the fields by hand
/// keeps every field in the log line, and means a field added later shows up
/// without anyone remembering to edit this file.
private func describeFields<T>(of value: T) -> String {
    let fields = Mirror(reflecting: value).children.map { child in
        "\(child.label ?? "_"): \(String(describing: child.value))"
    }
    return "\(T.self)(\(fields.joined(separator: ", ")))"
}
