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
import Testing

@testable import ContainerizationOCI

/// Decoding of externally-authored seccomp profiles.
///
/// The runtime spec marks nearly every field of `LinuxSeccomp`, `LinuxSyscall`
/// and `LinuxSeccompArg` `omitempty`, so these pin the shapes that appear on
/// disk rather than the always-complete shape our own encoder produces.
struct SeccompProfileDecodingTests {
    /// The smallest profile the runtime spec permits: a default action and one
    /// unconditional rule, with every `omitempty` field omitted.
    @Test func minimalProfileDecodes() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ALLOW",
              "syscalls": [
                { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO" }
              ]
            }
            """
        let profile = try JSONDecoder().decode(LinuxSeccomp.self, from: Data(json.utf8))

        #expect(profile.defaultAction == .actAllow)
        #expect(profile.defaultErrnoRet == nil)
        #expect(profile.architectures == [])
        #expect(profile.flags == [])
        #expect(profile.listenerPath == "")
        #expect(profile.listenerMetadata == "")
        #expect(profile.syscalls.count == 1)
        #expect(profile.syscalls.first?.names == ["mkdir", "mkdirat"])
        #expect(profile.syscalls.first?.action == .actErrno)
        #expect(profile.syscalls.first?.errnoRet == nil)
        #expect(profile.syscalls.first?.args.isEmpty == true)
    }

    /// A profile with nothing but a default action. Legal per the spec (`syscalls`
    /// is `omitempty`) and meaningful -- `SCMP_ACT_ERRNO` with no rules denies
    /// everything.
    @Test func profileWithNoSyscallsDecodes() throws {
        let json = #"{"defaultAction": "SCMP_ACT_ERRNO"}"#
        let profile = try JSONDecoder().decode(LinuxSeccomp.self, from: Data(json.utf8))

        #expect(profile.defaultAction == .actErrno)
        #expect(profile.syscalls.isEmpty)
        #expect(profile.architectures == [])
    }

    /// `LinuxSeccompArg.valueTwo` is `omitempty`, so every argument filter that
    /// does not use a mask omits it -- which is every one containerd's default
    /// profile emits.
    @Test func argumentWithoutValueTwoDecodes() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "architectures": ["SCMP_ARCH_AARCH64"],
              "syscalls": [
                {
                  "names": ["socket"],
                  "action": "SCMP_ACT_ALLOW",
                  "args": [{ "index": 0, "value": 38, "op": "SCMP_CMP_LT" }]
                }
              ]
            }
            """
        let profile = try JSONDecoder().decode(LinuxSeccomp.self, from: Data(json.utf8))

        #expect(profile.architectures == [.archAARCH64])
        let arg = try #require(profile.syscalls.first?.args.first)
        #expect(arg.index == 0)
        #expect(arg.value == 38)
        #expect(arg.valueTwo == 0)
        #expect(arg.op == .opLessThan)
    }

    /// The fields that *are* present still have to be read, not defaulted away.
    @Test func fullyPopulatedProfileDecodes() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "defaultErrnoRet": 38,
              "architectures": ["SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM"],
              "flags": ["SECCOMP_FILTER_FLAG_LOG"],
              "listenerPath": "/run/seccomp-agent.sock",
              "listenerMetadata": "hello",
              "syscalls": [
                {
                  "names": ["clone"],
                  "action": "SCMP_ACT_ERRNO",
                  "errnoRet": 1,
                  "args": [{ "index": 0, "value": 2114060288, "valueTwo": 7, "op": "SCMP_CMP_MASKED_EQ" }]
                }
              ]
            }
            """
        let profile = try JSONDecoder().decode(LinuxSeccomp.self, from: Data(json.utf8))

        #expect(profile.defaultAction == .actErrno)
        #expect(profile.defaultErrnoRet == 38)
        #expect(profile.architectures == [.archAARCH64, .archARM])
        #expect(profile.flags == [.flagLog])
        #expect(profile.listenerPath == "/run/seccomp-agent.sock")
        #expect(profile.listenerMetadata == "hello")
        let syscall = try #require(profile.syscalls.first)
        #expect(syscall.errnoRet == 1)
        let arg = try #require(syscall.args.first)
        #expect(arg.value == 2_114_060_288)
        #expect(arg.valueTwo == 7)
        #expect(arg.op == .opMaskedEqual)
    }

    /// `defaultAction` is the one field the spec does not mark `omitempty`, and
    /// it has no safe default.
    @Test func profileWithoutDefaultActionIsRejected() {
        let json = #"{"syscalls": [{"names": ["mkdir"], "action": "SCMP_ACT_ERRNO"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LinuxSeccomp.self, from: Data(json.utf8))
        }
    }

    /// `names` is likewise required on a rule. A rule that matches no syscall is
    /// not a rule.
    @Test func syscallWithoutNamesIsRejected() {
        let json = #"{"defaultAction": "SCMP_ACT_ALLOW", "syscalls": [{"action": "SCMP_ACT_ERRNO"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LinuxSeccomp.self, from: Data(json.utf8))
        }
    }
}

/// ``LinuxSeccomp/decode(from:)`` — the loader every consumer of an
/// externally-authored profile goes through, and the only place the OCI /
/// Docker format distinction is enforced.
struct SeccompProfileLoaderTests {
    /// A minimal, spec-conformant profile with no `args` on its one rule and
    /// none of the `omitempty` top-level fields.
    @Test func minimalOCIProfileDecodes() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ALLOW",
              "syscalls": [
                { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO", "errnoRet": 13 }
              ]
            }
            """
        let profile = try LinuxSeccomp.decode(from: Data(json.utf8))

        #expect(profile.defaultAction == .actAllow)
        #expect(profile.syscalls.count == 1)
        #expect(profile.syscalls.first?.names == ["mkdir", "mkdirat"])
        #expect(profile.syscalls.first?.action == .actErrno)
        #expect(profile.syscalls.first?.errnoRet == 13)
        #expect(profile.syscalls.first?.args.isEmpty == true)
    }

    /// Decode → encode → decode is stable: the profile is re-encoded into the
    /// spec the host ships over vsock, decoded in vminitd, and re-encoded again
    /// into runc's bundle `config.json`.
    @Test func profileSurvivesARoundTrip() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "defaultErrnoRet": 38,
              "architectures": ["SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM"],
              "flags": ["SECCOMP_FILTER_FLAG_LOG"],
              "syscalls": [
                { "names": ["read", "write"], "action": "SCMP_ACT_ALLOW" },
                {
                  "names": ["clone"],
                  "action": "SCMP_ACT_ALLOW",
                  "args": [{ "index": 0, "value": 2114060288, "op": "SCMP_CMP_MASKED_EQ" }]
                },
                { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO", "errnoRet": 13 }
              ]
            }
            """
        let first = try LinuxSeccomp.decode(from: Data(json.utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(first)
        let second = try LinuxSeccomp.decode(from: encoded)

        #expect(second.defaultAction == first.defaultAction)
        #expect(second.defaultErrnoRet == first.defaultErrnoRet)
        #expect(second.architectures == first.architectures)
        #expect(second.flags == first.flags)
        #expect(second.listenerPath == first.listenerPath)
        #expect(second.listenerMetadata == first.listenerMetadata)
        #expect(second.syscalls.map(\.names) == first.syscalls.map(\.names))
        #expect(second.syscalls.map(\.action) == first.syscalls.map(\.action))
        #expect(second.syscalls.map(\.errnoRet) == first.syscalls.map(\.errnoRet))
        #expect(second.syscalls.map { $0.args.map(\.value) } == first.syscalls.map { $0.args.map(\.value) })
        #expect(second.syscalls.map { $0.args.map(\.valueTwo) } == first.syscalls.map { $0.args.map(\.valueTwo) })
        #expect(second.syscalls.map { $0.args.map(\.op) } == first.syscalls.map { $0.args.map(\.op) })

        // Re-encoding the second decode is byte-identical to the first, so no
        // information is lost on any later hop.
        let reencoded = try encoder.encode(second)
        #expect(reencoded == encoded)

        // The loader also has to keep accepting what our own encoder emits: it
        // is the shape the guest decodes.
        let keys = String(decoding: encoded, as: UTF8.self)
        #expect(keys.contains("\"defaultAction\":\"SCMP_ACT_ERRNO\""))
        #expect(keys.contains("\"syscalls\":["))
    }

    /// The core rejection. A JSON decoder ignores Docker's extra keys, so
    /// `mount`, `keyctl`, `bpf` and friends would each silently become an
    /// unconditional allow. The message names the format.
    @Test func dockerFormatProfileIsRejected() throws {
        // The shape of moby's profiles/seccomp/default.json, cut down to the
        // one rule that matters: `mount` is allowed only with CAP_SYS_ADMIN.
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "archMap": [
                { "architecture": "SCMP_ARCH_X86_64", "subArchitectures": ["SCMP_ARCH_X86", "SCMP_ARCH_X32"] }
              ],
              "syscalls": [
                { "names": ["read", "write"], "action": "SCMP_ACT_ALLOW" },
                {
                  "names": ["mount", "umount2"],
                  "action": "SCMP_ACT_ALLOW",
                  "includes": { "caps": ["CAP_SYS_ADMIN"] }
                }
              ]
            }
            """
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("Docker"))
        #expect(error.description.contains("OCI"))
    }

    /// `includes` alone, with no `archMap`, is still Docker's format. This is
    /// the marker that actually changes the filter's meaning.
    @Test func dockerIncludesAloneIsRejected() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "syscalls": [
                { "names": ["bpf"], "action": "SCMP_ACT_ALLOW", "includes": { "caps": ["CAP_SYS_ADMIN"] } }
              ]
            }
            """
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("Docker"))
        #expect(error.description.contains("includes"))
    }

    /// `excludes` is the same hazard inverted: Docker uses it to *withhold* a
    /// rule from some containers, so dropping it applies the rule to all of them.
    @Test func dockerExcludesIsRejected() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "syscalls": [
                {
                  "names": ["clone"],
                  "action": "SCMP_ACT_ALLOW",
                  "excludes": { "caps": ["CAP_SYS_ADMIN"] },
                  "args": [{ "index": 0, "value": 2114060288, "op": "SCMP_CMP_MASKED_EQ" }]
                }
              ]
            }
            """
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("Docker"))
        #expect(error.description.contains("excludes"))
    }

    /// Docker's `minKernel` is a version gate. Silently ignoring it enables a
    /// rule on kernels its author excluded.
    @Test func dockerMinKernelIsRejected() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "syscalls": [
                { "names": ["faccessat2"], "action": "SCMP_ACT_ALLOW", "minKernel": "5.8" }
              ]
            }
            """
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("Docker"))
        #expect(error.description.contains("minKernel"))
    }

    /// Docker's legacy singular `name`. Without the rejection this is a bare
    /// `keyNotFound: names`, which points at the wrong problem.
    @Test func dockerSingularSyscallNameIsRejected() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "syscalls": [{ "name": "read", "action": "SCMP_ACT_ALLOW" }]
            }
            """
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("Docker"))
        #expect(error.description.contains("names"))
    }

    /// `comment` is inert, so a profile carrying only comments is still an OCI
    /// profile and must not be swept up by the format check.
    @Test func commentsAloneAreNotDockerFormat() throws {
        let json = """
            {
              "defaultAction": "SCMP_ACT_ERRNO",
              "syscalls": [
                { "names": ["read"], "action": "SCMP_ACT_ALLOW", "comment": "why not" }
              ]
            }
            """
        let profile = try LinuxSeccomp.decode(from: Data(json.utf8))
        #expect(profile.syscalls.first?.names == ["read"])
    }

    /// A profile with no `defaultAction` describes no filter. Rejected by name
    /// rather than allowed to produce something inert.
    @Test func profileWithoutDefaultActionIsRejected() throws {
        let json = #"{"syscalls": [{"names": ["mkdir"], "action": "SCMP_ACT_ERRNO"}]}"#
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("defaultAction"))
    }

    /// An empty object hits the same check. So does an empty file, below.
    @Test func emptyObjectIsRejected() throws {
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data("{}".utf8))
        }
        #expect(error.description.contains("defaultAction"))
    }

    @Test func emptyInputIsRejected() throws {
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data())
        }
        #expect(error.description.contains("not valid JSON"))
    }

    /// A whole `config.json` handed over by mistake is a JSON object with no
    /// top-level `defaultAction`, so it lands on that check.
    @Test func nonProfileJSONObjectIsRejected() throws {
        let json = #"{"ociVersion": "1.2.0", "linux": {"seccomp": {"defaultAction": "SCMP_ACT_ALLOW"}}}"#
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("defaultAction"))
    }

    /// A JSON array, or any other non-object, is not a profile.
    @Test func jsonArrayIsRejected() throws {
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data("[]".utf8))
        }
        #expect(error.description.contains("not a JSON object"))
    }

    /// An unknown action is a decode failure, and the message says so rather
    /// than blaming the format.
    @Test func unknownActionIsRejected() throws {
        let json = #"{"defaultAction": "SCMP_ACT_PLEASE"}"#
        let error = try #require(throws: ContainerizationError.self) {
            try LinuxSeccomp.decode(from: Data(json.utf8))
        }
        #expect(error.description.contains("could not be decoded"))
        #expect(!error.description.contains("Docker"))
    }
}
