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

// https://man7.org/linux/man-pages/man2/seccomp.2.html

import ContainerizationOCI

public struct BPFInstruction: Equatable, Sendable {
    public var code: UInt16
    public var jt: UInt8
    public var jf: UInt8
    public var k: UInt32

    public init(code: UInt16, jt: UInt8, jf: UInt8, k: UInt32) {
        self.code = code
        self.jt = jt
        self.jf = jf
        self.k = k
    }
}

enum BPF {
    enum InstructionClass {
        static let ld: UInt16 = 0x00
        static let jmp: UInt16 = 0x05
        static let ret: UInt16 = 0x06
        static let alu: UInt16 = 0x04
    }

    enum Size {
        static let w: UInt16 = 0x00
    }

    enum Mode {
        static let abs: UInt16 = 0x20
    }

    enum Source {
        static let k: UInt16 = 0x00
    }

    enum JumpTest {
        static let eq: UInt16 = 0x10
        static let gt: UInt16 = 0x20
        static let ge: UInt16 = 0x30
        static let set: UInt16 = 0x40
        static let always: UInt16 = 0x00
    }

    enum ALUOp {
        static let and: UInt16 = 0x50
    }
}

enum SeccompData {
    static let nr: UInt32 = 0
    static let arch: UInt32 = 4
    // args start at offset 16, each is 8 bytes (two 32-bit halves: lo at offset, hi at offset+4)
    static let args: UInt32 = 16
}

enum SeccompReturn {
    static let killThread: UInt32 = 0x0000_0000
    static let killProcess: UInt32 = 0x8000_0000
    static let trap: UInt32 = 0x0003_0000
    static let errno: UInt32 = 0x0005_0000
    static let trace: UInt32 = 0x7FF0_0000
    static let log: UInt32 = 0x7FFC_0000
    static let allow: UInt32 = 0x7FFF_0000
    static let notify: UInt32 = 0x7FC0_0000
}

enum AuditArch {
    static let aarch64: UInt32 = 0xC000_00B7
}

extension LinuxSeccompFlag {
    public var kernelFlag: UInt32 {
        switch self {
        case .flagLog:
            return 1 << 1
        case .flagSpecAllow:
            return 1 << 2
        case .flagWaitKillableRecv:
            return 1 << 5
        }
    }
}

public enum SeccompCompiler {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unknownSyscall(String)
        case invalidArgIndex(UInt)

        public var description: String {
            switch self {
            case .unknownSyscall(let name):
                return "unknown syscall: \(name)"
            case .invalidArgIndex(let idx):
                return "invalid syscall arg index: \(idx), must be 0-5"
            }
        }
    }

    /// Compiles an OCI `LinuxSeccomp` configuration into a classic BPF (cBPF)
    /// filter program.
    ///
    /// The kernel evaluates the BPF program on every syscall. The program inspects
    /// a read-only `seccomp_data` struct:
    ///
    ///     struct seccomp_data {
    ///         int   nr;        // offset 0:  syscall number
    ///         __u32 arch;      // offset 4:  AUDIT_ARCH_* value
    ///         __u64 ip;        // offset 8:  instruction pointer (unused)
    ///         __u64 args[6];   // offset 16: syscall arguments, 8 bytes each
    ///     };
    ///
    /// Each BPF instruction is 8 bytes: a 16-bit opcode, two 8-bit jump offsets
    /// (jt = jump-true, jf = jump-false, relative to the next instruction), and
    /// a 32-bit immediate value (k). The program terminates when it executes a
    /// RET instruction whose k value is the seccomp action (e.g. ALLOW, ERRNO).
    ///
    /// EXAMPLE: blocking `mkdirat` with ERRNO(EPERM), default ALLOW
    ///
    /// Given this OCI config:
    ///
    ///     defaultAction: SCMP_ACT_ALLOW
    ///     syscalls: [{ names: ["mkdirat"], action: SCMP_ACT_ERRNO, errnoRet: 1 }]
    ///
    /// The compiler produces:
    ///
    ///     [0] LD_ABS  [seccomp_data.arch]       // load arch into accumulator
    ///     [1] JEQ     AUDIT_ARCH_AARCH64  1, 0  // match → skip 1 to [3]; miss → fall to [2]
    ///     [2] RET     KILL_PROCESS              // wrong arch → kill
    ///     [3] LD_ABS  [seccomp_data.nr]         // load syscall number into accumulator
    ///     [4] JEQ     34 (mkdirat)        0, 1  // match → fall to [5]; miss → skip 1 to [6]
    ///     [5] RET     ERRNO|EPERM               // blocked syscall → return -EPERM
    ///     [6] RET     ALLOW                     // no rule matched → allow
    ///
    /// Jump offsets (jt, jf) are relative to the *next* instruction. A JEQ with
    /// jt=1,jf=0 means: if equal, skip 1 instruction forward; if not equal, fall
    /// through to the very next instruction (skip 0).
    ///
    /// EXAMPLE: blocking multiple syscalls
    ///
    /// Each syscall in the rule list becomes a JEQ+RET pair. The syscall number
    /// stays in the accumulator across rules, so no reload is needed:
    ///
    ///     syscalls: [
    ///       { names: ["mkdirat"],  action: SCMP_ACT_ERRNO, errnoRet: 1 },
    ///       { names: ["unlinkat"], action: SCMP_ACT_KILL_PROCESS },
    ///     ]
    ///
    ///     [0] LD_ABS  [seccomp_data.arch]
    ///     [1] JEQ     AUDIT_ARCH_AARCH64  1, 0
    ///     [2] RET     KILL_PROCESS
    ///     [3] LD_ABS  [seccomp_data.nr]
    ///     [4] JEQ     34 (mkdirat)        0, 1  // miss → skip to [6]
    ///     [5] RET     ERRNO|EPERM
    ///     [6] JEQ     35 (unlinkat)       0, 1  // miss → skip to [8]
    ///     [7] RET     KILL_PROCESS
    ///     [8] RET     ALLOW
    ///
    /// For rules with argument filters, the compiler inserts additional LD/JEQ
    /// sequences between the syscall number match and the action RET. Because BPF
    /// is a 32-bit machine, 64-bit arguments are compared as two 32-bit halves
    /// (lo at the base offset, hi at base+4, little-endian).
    public static func compileFromOCI(config: ContainerizationOCI.LinuxSeccomp) throws -> [BPFInstruction] {
        var prog: [BPFInstruction] = []

        // 1. Check architecture: load seccomp_data.arch
        prog.append(BPFInstruction(code: BPF.InstructionClass.ld | BPF.Size.w | BPF.Mode.abs, jt: 0, jf: 0, k: SeccompData.arch))

        // We only support AARCH64 today, so if arch != AARCH64 kill the process.
        prog.append(BPFInstruction(code: BPF.InstructionClass.jmp | BPF.JumpTest.eq | BPF.Source.k, jt: 1, jf: 0, k: AuditArch.aarch64))
        prog.append(BPFInstruction(code: BPF.InstructionClass.ret | BPF.Source.k, jt: 0, jf: 0, k: SeccompReturn.killProcess))

        // 2. Load syscall number
        prog.append(BPFInstruction(code: BPF.InstructionClass.ld | BPF.Size.w | BPF.Mode.abs, jt: 0, jf: 0, k: SeccompData.nr))

        // 3. Per-rule matching
        for syscall in config.syscalls {
            let action = mapAction(syscall.action, errnoRet: syscall.errnoRet)

            for name in syscall.names {
                guard let nr = Self.aarch64SyscallTable[name] ?? UInt32(name) else {
                    // Skip unknown syscall names that aren't valid numbers
                    continue
                }

                if syscall.args.isEmpty {
                    // Simple case: JEQ nr -> return action, else fall through
                    // We need: JEQ nr, 0, 1 (if equal, execute next which is RET; else skip RET)
                    prog.append(BPFInstruction(code: BPF.InstructionClass.jmp | BPF.JumpTest.eq | BPF.Source.k, jt: 0, jf: 1, k: nr))
                    prog.append(BPFInstruction(code: BPF.InstructionClass.ret | BPF.Source.k, jt: 0, jf: 0, k: action))
                } else {
                    // With arg filters: JEQ nr -> arg checks -> return action
                    // First, build the arg check instructions
                    let argBlock = try buildArgBlock(args: syscall.args, action: action)
                    // JEQ nr, 0, skip_arg_block
                    let skipCount = UInt8(argBlock.count)
                    prog.append(BPFInstruction(code: BPF.InstructionClass.jmp | BPF.JumpTest.eq | BPF.Source.k, jt: 0, jf: skipCount, k: nr))
                    prog.append(contentsOf: argBlock)
                }
            }
        }

        // 4. Default action
        let defaultAction = mapAction(config.defaultAction, errnoRet: config.defaultErrnoRet)
        prog.append(BPFInstruction(code: BPF.InstructionClass.ret | BPF.Source.k, jt: 0, jf: 0, k: defaultAction))

        return prog
    }

    /// Map kernel flags from OCI config flags.
    public static func mapFlags(_ flags: [LinuxSeccompFlag]) -> UInt32 {
        var result: UInt32 = 0
        for flag in flags {
            result |= flag.kernelFlag
        }
        return result
    }

    static func mapAction(_ action: LinuxSeccompAction, errnoRet: UInt?) -> UInt32 {
        switch action {
        case .actKill, .actKillThread:
            return SeccompReturn.killThread
        case .actKillProcess:
            return SeccompReturn.killProcess
        case .actTrap:
            return SeccompReturn.trap
        case .actErrno:
            let errno = UInt32(errnoRet ?? 0) & 0xFFFF
            return SeccompReturn.errno | errno
        case .actTrace:
            return SeccompReturn.trace
        case .actLog:
            return SeccompReturn.log
        case .actAllow:
            return SeccompReturn.allow
        case .actNotify:
            return SeccompReturn.notify
        }
    }

    enum JumpField { case jt, jf, k }

    /// Build BPF instructions for argument comparison.
    ///
    /// Each argument is 64-bit but BPF operates on 32-bit values, so we compare
    /// the low and high 32-bit halves separately. All arg conditions must match
    /// (AND semantics) for the action to be taken.
    static func buildArgBlock(args: [LinuxSeccompArg], action: UInt32) throws -> [BPFInstruction] {
        // We build the arg checks. If any check fails, we need to jump past
        // the remaining checks and the final RET action instruction.
        // We'll build everything first, then fix up the failure jumps.

        // Each failure jump records the instruction index and which field
        // holds the jump offset. Most use jf (conditional false branch),
        // but LT/LE use jt (the "true" branch of JGT/JGE is the fail path)
        // and NE uses k (unconditional JA jump).
        var checks: [(instructions: [BPFInstruction], failureJumps: [(index: Int, field: JumpField)])] = []

        for arg in args {
            guard arg.index <= 5 else {
                throw Error.invalidArgIndex(arg.index)
            }

            let check = try buildSingleArgCheck(arg: arg)
            checks.append(check)
        }

        // Flatten all checks and add the final RET.
        var flat: [BPFInstruction] = []
        var failureJumps: [(index: Int, field: JumpField)] = []

        for check in checks {
            let baseIndex = flat.count
            flat.append(contentsOf: check.instructions)
            for (idx, field) in check.failureJumps {
                failureJumps.append((baseIndex + idx, field))
            }
        }

        // Append the success RET
        flat.append(BPFInstruction(code: BPF.InstructionClass.ret | BPF.Source.k, jt: 0, jf: 0, k: action))

        // Fix up failure jumps to point past the RET.
        // BPF jump offsets are relative to the next instruction.
        // jump offset = target - (current + 1) = flat.count - idx - 1
        for (idx, field) in failureJumps {
            let jumpOffset = flat.count - idx - 1
            switch field {
            case .jt: flat[idx].jt = UInt8(jumpOffset)
            case .jf: flat[idx].jf = UInt8(jumpOffset)
            case .k: flat[idx].k = UInt32(jumpOffset)
            }
        }

        // Reload the syscall number after arg checks for the next rule
        flat.append(BPFInstruction(code: BPF.InstructionClass.ld | BPF.Size.w | BPF.Mode.abs, jt: 0, jf: 0, k: SeccompData.nr))

        return flat
    }

    /// Build instructions for a single argument comparison.
    /// Returns instructions and failure jumps (index + which field to patch).
    static func buildSingleArgCheck(arg: LinuxSeccompArg) throws -> (instructions: [BPFInstruction], failureJumps: [(index: Int, field: JumpField)]) {
        let argOffset = SeccompData.args + UInt32(arg.index) * 8
        let loOffset = argOffset  // low 32 bits
        let hiOffset = argOffset + 4  // high 32 bits

        let valueLo = UInt32(arg.value & 0xFFFF_FFFF)
        let valueHi = UInt32(arg.value >> 32)
        let valueTwoLo = UInt32(arg.valueTwo & 0xFFFF_FFFF)
        let valueTwoHi = UInt32(arg.valueTwo >> 32)

        let ldAbs = BPF.InstructionClass.ld | BPF.Size.w | BPF.Mode.abs
        let jmpEq = BPF.InstructionClass.jmp | BPF.JumpTest.eq | BPF.Source.k
        let jmpGt = BPF.InstructionClass.jmp | BPF.JumpTest.gt | BPF.Source.k
        let jmpGe = BPF.InstructionClass.jmp | BPF.JumpTest.ge | BPF.Source.k
        let jmpAlways = BPF.InstructionClass.jmp | BPF.JumpTest.always | BPF.Source.k
        let aluAnd = BPF.InstructionClass.alu | BPF.ALUOp.and | BPF.Source.k

        var insts: [BPFInstruction] = []
        var fails: [(index: Int, field: JumpField)] = []

        switch arg.op {
        case .opEqualTo:
            // EQ: both halves must match. Fail (jf) if either doesn't.
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 0, k: valueHi))
            fails.append((insts.count - 1, .jf))
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 0, k: valueLo))
            fails.append((insts.count - 1, .jf))

        case .opNotEqual:
            // NE: succeed if either half differs. Fail if both match.
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            // hi differs → success (skip 3 past lo check)
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 3, k: valueHi))
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            // lo differs → success (skip 1 past fail jump)
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 1, k: valueLo))
            // Both matched → NE fails. JA uses k for the offset.
            insts.append(BPFInstruction(code: jmpAlways, jt: 0, jf: 0, k: 0))
            fails.append((insts.count - 1, .k))

        case .opGreaterThan:
            // GT: hi > v_hi → success; hi == v_hi → check lo > v_lo; else fail.
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            insts.append(BPFInstruction(code: jmpGt, jt: 3, jf: 0, k: valueHi))
            // hi not greater; check if equal
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 0, k: valueHi))
            fails.append((insts.count - 1, .jf))  // hi < v_hi → fail
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            insts.append(BPFInstruction(code: jmpGt, jt: 0, jf: 0, k: valueLo))
            fails.append((insts.count - 1, .jf))  // lo <= v_lo → fail

        case .opGreaterEqual:
            // GE: hi > v_hi → success; hi == v_hi → check lo >= v_lo; else fail.
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            insts.append(BPFInstruction(code: jmpGt, jt: 3, jf: 0, k: valueHi))
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 0, k: valueHi))
            fails.append((insts.count - 1, .jf))
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            insts.append(BPFInstruction(code: jmpGe, jt: 0, jf: 0, k: valueLo))
            fails.append((insts.count - 1, .jf))

        case .opLessThan:
            // LT: hi < v_hi → success; hi == v_hi → check lo < v_lo; else fail.
            // JGT true means hi > v_hi → fail (on jt).
            // JGT false + JEQ false means hi < v_hi → success (skip past lo check).
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            insts.append(BPFInstruction(code: jmpGt, jt: 0, jf: 0, k: valueHi))
            fails.append((insts.count - 1, .jt))  // hi > v_hi → fail
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 3, k: valueHi))
            // hi < v_hi → skip 3 to success (past lo check)
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            insts.append(BPFInstruction(code: jmpGe, jt: 0, jf: 0, k: valueLo))
            fails.append((insts.count - 1, .jt))  // lo >= v_lo → fail

        case .opLessEqual:
            // LE: hi < v_hi → success; hi == v_hi → check lo <= v_lo; else fail.
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            insts.append(BPFInstruction(code: jmpGt, jt: 0, jf: 0, k: valueHi))
            fails.append((insts.count - 1, .jt))  // hi > v_hi → fail
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 3, k: valueHi))
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            insts.append(BPFInstruction(code: jmpGt, jt: 0, jf: 0, k: valueLo))
            fails.append((insts.count - 1, .jt))  // lo > v_lo → fail

        case .opMaskedEqual:
            // MASKED_EQ: (data & value) == valueTwo, checked per-half.
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: hiOffset))
            insts.append(BPFInstruction(code: aluAnd, jt: 0, jf: 0, k: UInt32(valueHi)))
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 0, k: valueTwoHi))
            fails.append((insts.count - 1, .jf))
            insts.append(BPFInstruction(code: ldAbs, jt: 0, jf: 0, k: loOffset))
            insts.append(BPFInstruction(code: aluAnd, jt: 0, jf: 0, k: UInt32(valueLo)))
            insts.append(BPFInstruction(code: jmpEq, jt: 0, jf: 0, k: valueTwoLo))
            fails.append((insts.count - 1, .jf))
        }

        return (insts, fails)
    }
}
