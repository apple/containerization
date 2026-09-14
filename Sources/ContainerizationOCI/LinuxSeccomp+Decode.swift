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

import ContainerizationError
import Foundation

extension LinuxSeccomp {
    /// Decodes a seccomp profile from OCI runtime-spec JSON — the object that
    /// appears at `linux.seccomp` in a `config.json`, stored on its own.
    ///
    /// Use this rather than `JSONDecoder` directly: it refuses Docker-format
    /// profiles, which decode cleanly and silently wrong. Docker gates `mount`,
    /// `keyctl`, `bpf` and others behind `includes` / `excludes` conditions the
    /// runtime spec has no equivalent for, so dropping them turns each into an
    /// unconditional allow. Convert such a profile to the runtime-spec format
    /// instead; resolving Docker's conditions is not implemented.
    ///
    /// - Parameter data: The profile's JSON.
    /// - Returns: The decoded profile.
    /// - Throws: `ContainerizationError(.invalidArgument)` when the input is not
    ///   a JSON object, is in Docker's format, has no `defaultAction`, or
    ///   otherwise cannot be decoded.
    public static func decode(from data: Data) throws -> LinuxSeccomp {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "seccomp profile is not a JSON object: expected the contents of the runtime spec's `linux.seccomp`, which is a single object"
                )
            }
            object = parsed
        } catch let error as ContainerizationError {
            throw error
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "seccomp profile is not valid JSON: \(error)"
            )
        }

        if let marker = Self.dockerFormatMarker(in: object) {
            throw ContainerizationError(
                .invalidArgument,
                message: """
                    seccomp profile is in Docker's format, not the OCI runtime spec's (found \(marker)). \
                    Docker gates syscalls such as mount, keyctl and bpf behind includes/excludes conditions that the OCI \
                    runtime spec has no equivalent for; accepting the file would drop those conditions and turn every gated \
                    rule into an unconditional allow, producing a filter quietly more permissive than the profile asked for. \
                    Convert it to the OCI format — the object shape of `linux.seccomp` in a config.json — instead.
                    """
            )
        }

        // Checked before decoding only to name the commonest mistakes — an
        // empty file, or a profile nested one level down — rather than report
        // a decoder key error. The decoder requires the key too.
        guard object["defaultAction"] != nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "seccomp profile has no `defaultAction`: a profile without one describes no filter at all, and there is no safe default to assume"
            )
        }

        do {
            return try JSONDecoder().decode(LinuxSeccomp.self, from: data)
        } catch {
            throw ContainerizationError(
                .invalidArgument,
                message: "seccomp profile could not be decoded as an OCI runtime spec seccomp object: \(error)"
            )
        }
    }

    /// The first Docker-format marker found in `object`, described for a human,
    /// or `nil` when the object carries none.
    ///
    /// From moby's `profiles/seccomp/types.go`. Only the load-bearing additions
    /// are matched: `comment` is inert, so a file carrying only comments is
    /// still an OCI profile. Keys are spelled as literals because what is
    /// matched is the wire format, not a Swift property name.
    private static func dockerFormatMarker(in object: [String: Any]) -> String? {
        for key in ["archMap", "minKernel"] where object[key] != nil {
            return "\"\(key)\" at the top level"
        }

        guard let syscalls = object["syscalls"] as? [Any] else {
            return nil
        }
        for case let syscall as [String: Any] in syscalls {
            for key in ["includes", "excludes", "minKernel"] where syscall[key] != nil {
                return "\"\(key)\" on a syscall entry"
            }
            // Docker's legacy singular `name`; without `names` the entry cannot
            // decode anyway, so name the format rather than emit `keyNotFound`.
            if syscall["name"] != nil, syscall["names"] == nil {
                return "\"name\" rather than \"names\" on a syscall entry"
            }
        }
        return nil
    }
}
