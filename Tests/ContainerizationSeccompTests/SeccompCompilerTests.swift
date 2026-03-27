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
import ContainerizationSeccomp
import Testing

private let aarch64: UInt32 = 0xC000_00B7
private let retAllow: UInt32 = 0x7FFF_0000
private let retKillProcess: UInt32 = 0x8000_0000

private func retErrno(_ errno: UInt32) -> UInt32 { 0x0005_0000 | errno }

private func makeConfig(
    defaultAction: LinuxSeccompAction = .actAllow,
    defaultErrnoRet: UInt? = nil,
    syscalls: [LinuxSyscall] = []
) -> LinuxSeccomp {
    LinuxSeccomp(
        defaultAction: defaultAction,
        defaultErrnoRet: defaultErrnoRet,
        architectures: [],
        flags: [],
        listenerPath: "",
        listenerMetadata: "",
        syscalls: syscalls
    )
}

@Suite("SeccompCompiler")
struct SeccompCompilerTests {
    // MARK: - Architecture check

    @Test("kills process on wrong architecture")
    func wrongArchKills() throws {
        let prog = try SeccompCompiler.compileFromOCI(config: makeConfig())
        let result = BPFSimulator.run(prog, syscallNr: 0, arch: 0x1234_5678)
        #expect(result == retKillProcess)
    }

    @Test("allows syscall on aarch64")
    func correctArchAllows() throws {
        let prog = try SeccompCompiler.compileFromOCI(config: makeConfig())
        let result = BPFSimulator.run(prog, syscallNr: 56, arch: aarch64)  // openat
        #expect(result == retAllow)
    }

    // MARK: - Default action

    @Test("returns default allow when no rules match")
    func defaultAllow() throws {
        let prog = try SeccompCompiler.compileFromOCI(config: makeConfig(defaultAction: .actAllow))
        let result = BPFSimulator.run(prog, syscallNr: 56, arch: aarch64)
        #expect(result == retAllow)
    }

    @Test("returns default errno when no rules match")
    func defaultErrno() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1
            ))
        let result = BPFSimulator.run(prog, syscallNr: 56, arch: aarch64)
        #expect(result == retErrno(1))
    }

    // MARK: - Simple syscall blocking

    @Test("blocks specific syscall with errno, allows others")
    func blockSyscallErrno() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["mkdirat"], action: .actErrno, errnoRet: 1, args: [])
                ]
            ))

        // mkdirat (34) → ERRNO|1
        #expect(BPFSimulator.run(prog, syscallNr: 34, arch: aarch64) == retErrno(1))
        // openat (56) → ALLOW (default)
        #expect(BPFSimulator.run(prog, syscallNr: 56, arch: aarch64) == retAllow)
        // read (63) → ALLOW (default)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64) == retAllow)
    }

    @Test("blocks specific syscall with kill process")
    func blockSyscallKill() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["mkdirat"], action: .actKillProcess, errnoRet: nil, args: [])
                ]
            ))

        #expect(BPFSimulator.run(prog, syscallNr: 34, arch: aarch64) == retKillProcess)
        #expect(BPFSimulator.run(prog, syscallNr: 56, arch: aarch64) == retAllow)
    }

    @Test("errno passes through explicit errno value")
    func errnoExplicitValue() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["mkdirat"], action: .actErrno, errnoRet: 100, args: [])
                ]
            ))

        // ENETDOWN = 100
        #expect(BPFSimulator.run(prog, syscallNr: 34, arch: aarch64) == retErrno(100))
    }

    // MARK: - Multiple rules and syscalls

    @Test("multiple rules apply independently")
    func multipleRules() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["mkdirat"], action: .actErrno, errnoRet: 1, args: []),
                    LinuxSyscall(names: ["unlinkat"], action: .actKillProcess, errnoRet: nil, args: []),
                ]
            ))

        #expect(BPFSimulator.run(prog, syscallNr: 34, arch: aarch64) == retErrno(1))  // mkdirat
        #expect(BPFSimulator.run(prog, syscallNr: 35, arch: aarch64) == retKillProcess)  // unlinkat
        #expect(BPFSimulator.run(prog, syscallNr: 56, arch: aarch64) == retAllow)  // openat
    }

    @Test("multiple names in one rule all match")
    func multipleNamesOneRule() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["mkdirat", "unlinkat", "symlinkat"], action: .actErrno, errnoRet: 1, args: [])
                ]
            ))

        #expect(BPFSimulator.run(prog, syscallNr: 34, arch: aarch64) == retErrno(1))  // mkdirat
        #expect(BPFSimulator.run(prog, syscallNr: 35, arch: aarch64) == retErrno(1))  // unlinkat
        #expect(BPFSimulator.run(prog, syscallNr: 36, arch: aarch64) == retErrno(1))  // symlinkat
        #expect(BPFSimulator.run(prog, syscallNr: 56, arch: aarch64) == retAllow)  // openat
    }

    // MARK: - Unknown syscall names

    @Test("unknown syscall names are silently skipped")
    func unknownSyscallSkipped() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["open"], action: .actErrno, errnoRet: 1, args: [])
                ]
            ))

        // "open" doesn't exist on aarch64, no rule emitted, everything allowed
        #expect(BPFSimulator.run(prog, syscallNr: 56, arch: aarch64) == retAllow)
    }

    @Test("mixed known/unknown names: known names still match")
    func mixedKnownUnknown() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                syscalls: [
                    LinuxSyscall(names: ["open", "mkdirat"], action: .actErrno, errnoRet: 1, args: [])
                ]
            ))

        #expect(BPFSimulator.run(prog, syscallNr: 34, arch: aarch64) == retErrno(1))  // mkdirat matched
        #expect(BPFSimulator.run(prog, syscallNr: 56, arch: aarch64) == retAllow)  // openat unaffected
    }

    // MARK: - Argument filtering

    @Test("equalTo arg filter matches exact value")
    func argEqualTo() throws {
        // Allow personality(0) only, block everything else via default
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1,
                syscalls: [
                    LinuxSyscall(
                        names: ["personality"],
                        action: .actAllow,
                        errnoRet: nil,
                        args: [LinuxSeccompArg(index: 0, value: 0, valueTwo: 0, op: .opEqualTo)]
                    )
                ]
            ))

        // personality(0) → ALLOW
        #expect(BPFSimulator.run(prog, syscallNr: 92, arch: aarch64, args: [0]) == retAllow)
        // personality(8) → ERRNO (arg doesn't match)
        #expect(BPFSimulator.run(prog, syscallNr: 92, arch: aarch64, args: [8]) == retErrno(1))
        // personality(0xFFFFFFFF) → ERRNO
        #expect(BPFSimulator.run(prog, syscallNr: 92, arch: aarch64, args: [0xFFFF_FFFF]) == retErrno(1))
    }

    @Test("notEqual arg filter blocks exact value")
    func argNotEqual() throws {
        // Allow socket() unless arg0 == 40 (AF_VSOCK)
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1,
                syscalls: [
                    LinuxSyscall(
                        names: ["socket"],
                        action: .actAllow,
                        errnoRet: nil,
                        args: [LinuxSeccompArg(index: 0, value: 40, valueTwo: 0, op: .opNotEqual)]
                    )
                ]
            ))

        // socket(AF_INET=2) → ALLOW (not 40)
        #expect(BPFSimulator.run(prog, syscallNr: 198, arch: aarch64, args: [2]) == retAllow)
        // socket(AF_VSOCK=40) → ERRNO (arg == 40, NE fails)
        #expect(BPFSimulator.run(prog, syscallNr: 198, arch: aarch64, args: [40]) == retErrno(1))
        // socket(AF_UNIX=1) → ALLOW
        #expect(BPFSimulator.run(prog, syscallNr: 198, arch: aarch64, args: [1]) == retAllow)
    }

    @Test("maskedEqual arg filter checks flag mask")
    func argMaskedEqual() throws {
        // allow clone if (flags & 0x7E020000) == 0
        let cloneMask: UInt64 = 2_114_060_288  // 0x7E020000
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1,
                syscalls: [
                    LinuxSyscall(
                        names: ["clone"],
                        action: .actAllow,
                        errnoRet: nil,
                        args: [LinuxSeccompArg(index: 0, value: cloneMask, valueTwo: 0, op: .opMaskedEqual)]
                    )
                ]
            ))

        // clone(SIGCHLD=17) → ALLOW (no namespace flags set)
        #expect(BPFSimulator.run(prog, syscallNr: 220, arch: aarch64, args: [17]) == retAllow)
        // clone(CLONE_NEWUSER=0x10000000) → ERRNO (namespace flag set)
        #expect(BPFSimulator.run(prog, syscallNr: 220, arch: aarch64, args: [0x1000_0000]) == retErrno(1))
        // clone(CLONE_NEWPID=0x20000000) → ERRNO
        #expect(BPFSimulator.run(prog, syscallNr: 220, arch: aarch64, args: [0x2000_0000]) == retErrno(1))
        // clone(SIGCHLD | CLONE_THREAD=0x10000) → ALLOW (CLONE_THREAD not in mask)
        #expect(BPFSimulator.run(prog, syscallNr: 220, arch: aarch64, args: [UInt64(17 | 0x10000)]) == retAllow)
    }

    @Test("greaterThan arg filter")
    func argGreaterThan() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1,
                syscalls: [
                    LinuxSyscall(
                        names: ["read"],
                        action: .actAllow,
                        errnoRet: nil,
                        args: [LinuxSeccompArg(index: 2, value: 0, valueTwo: 0, op: .opGreaterThan)]
                    )
                ]
            ))

        // read(fd, buf, count=1) → ALLOW (1 > 0)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [0, 0, 1]) == retAllow)
        // read(fd, buf, count=0) → ERRNO (0 is not > 0)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [0, 0, 0]) == retErrno(1))
    }

    @Test("lessEqual arg filter")
    func argLessEqual() throws {
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1,
                syscalls: [
                    LinuxSyscall(
                        names: ["read"],
                        action: .actAllow,
                        errnoRet: nil,
                        args: [LinuxSeccompArg(index: 2, value: 4096, valueTwo: 0, op: .opLessEqual)]
                    )
                ]
            ))

        // count=4096 → ALLOW (4096 <= 4096)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [0, 0, 4096]) == retAllow)
        // count=4097 → ERRNO (4097 > 4096)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [0, 0, 4097]) == retErrno(1))
        // count=0 → ALLOW (0 <= 4096)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [0, 0, 0]) == retAllow)
    }

    // MARK: - 64-bit argument handling

    @Test("handles 64-bit argument values correctly")
    func arg64Bit() throws {
        let largeValue: UInt64 = 0x1_0000_0001  // Requires both hi and lo halves
        let prog = try SeccompCompiler.compileFromOCI(
            config: makeConfig(
                defaultAction: .actErrno,
                defaultErrnoRet: 1,
                syscalls: [
                    LinuxSyscall(
                        names: ["read"],
                        action: .actAllow,
                        errnoRet: nil,
                        args: [LinuxSeccompArg(index: 0, value: largeValue, valueTwo: 0, op: .opEqualTo)]
                    )
                ]
            ))

        // Exact match → ALLOW
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [largeValue]) == retAllow)
        // Just the low half → ERRNO (high half doesn't match)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [1]) == retErrno(1))
        // Just the high half → ERRNO (low half doesn't match)
        #expect(BPFSimulator.run(prog, syscallNr: 63, arch: aarch64, args: [0x1_0000_0000]) == retErrno(1))
    }

    // MARK: - Error handling

    @Test("rejects arg index > 5")
    func invalidArgIndex() {
        let config = makeConfig(
            syscalls: [
                LinuxSyscall(
                    names: ["read"],
                    action: .actErrno,
                    errnoRet: 1,
                    args: [LinuxSeccompArg(index: 6, value: 0, valueTwo: 0, op: .opEqualTo)]
                )
            ]
        )

        #expect(throws: SeccompCompiler.Error.self) {
            try SeccompCompiler.compileFromOCI(config: config)
        }
    }

    // MARK: - Flag mapping

    @Test("maps seccomp flags correctly")
    func flagMapping() {
        #expect(SeccompCompiler.mapFlags([]) == 0)
        #expect(SeccompCompiler.mapFlags([.flagLog]) == 2)
        #expect(SeccompCompiler.mapFlags([.flagSpecAllow]) == 4)
        #expect(SeccompCompiler.mapFlags([.flagLog, .flagSpecAllow]) == 6)
        #expect(SeccompCompiler.mapFlags([.flagWaitKillableRecv]) == 32)
    }
}
