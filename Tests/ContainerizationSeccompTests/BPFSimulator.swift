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

import ContainerizationSeccomp

/// A classic BPF (cBPF) interpreter for seccomp filters.
///
/// Executes a compiled BPF program against a simulated `seccomp_data` struct,
/// returning the seccomp return value (action + data). This allows testing
/// filter semantics on any OS.
enum BPFSimulator {
    /// Simulates a seccomp BPF program against the given inputs.
    ///
    /// The simulated `seccomp_data` layout (little-endian):
    /// - offset 0:  nr (syscall number, 32-bit)
    /// - offset 4:  arch (AUDIT_ARCH_*, 32-bit)
    /// - offset 8:  instruction_pointer (64-bit, unused)
    /// - offset 16: args[0] (64-bit)
    /// - offset 24: args[1] (64-bit)
    /// - ... up to args[5] at offset 56
    ///
    /// Returns the 32-bit seccomp return value, or nil if the program is invalid.
    static func run(
        _ program: [BPFInstruction],
        syscallNr: UInt32,
        arch: UInt32,
        args: [UInt64] = []
    ) -> UInt32? {
        // Build seccomp_data as a byte buffer (64 bytes)
        var data = [UInt8](repeating: 0, count: 64)

        // nr at offset 0 (little-endian)
        writeU32(&data, offset: 0, value: syscallNr)
        // arch at offset 4
        writeU32(&data, offset: 4, value: arch)
        // instruction_pointer at offset 8 (leave as 0)
        // args at offset 16, each 8 bytes
        for (i, arg) in args.prefix(6).enumerated() {
            let offset = 16 + i * 8
            writeU32(&data, offset: offset, value: UInt32(arg & 0xFFFF_FFFF))
            writeU32(&data, offset: offset + 4, value: UInt32(arg >> 32))
        }

        var accumulator: UInt32 = 0
        var pc = 0

        while pc < program.count {
            let inst = program[pc]
            let cls = inst.code & 0x07

            switch cls {
            case 0x00:  // BPF_LD
                let mode = inst.code & 0xE0
                guard mode == 0x20 else {
                    return nil
                }
                let offset = Int(inst.k)
                guard offset + 4 <= data.count else { return nil }
                accumulator = readU32(data, offset: offset)
                pc += 1

            case 0x04:  // BPF_ALU
                let op = inst.code & 0xF0
                let src = inst.code & 0x08
                let operand: UInt32 = src == 0 ? inst.k : 0  // BPF_K vs BPF_X (we only support K)
                switch op {
                case 0x00: accumulator &+= operand  // ADD
                case 0x10: accumulator &-= operand  // SUB
                case 0x20: accumulator &*= operand  // MUL
                case 0x30:
                    guard operand != 0 else { return nil }
                    accumulator /= operand  // DIV
                case 0x40: accumulator |= operand  // OR
                case 0x50: accumulator &= operand  // AND
                case 0x60: accumulator <<= operand  // LSH
                case 0x70: accumulator >>= operand  // RSH
                case 0x80: accumulator = ~accumulator  // NEG
                default: return nil
                }
                pc += 1

            case 0x05:  // BPF_JMP
                let op = inst.code & 0xF0
                let src = inst.code & 0x08
                let operand: UInt32 = src == 0 ? inst.k : 0

                switch op {
                case 0x00:  // JA (unconditional)
                    pc += 1 + Int(inst.k)
                case 0x10:  // JEQ
                    pc += 1 + Int(accumulator == operand ? inst.jt : inst.jf)
                case 0x20:  // JGT
                    pc += 1 + Int(accumulator > operand ? inst.jt : inst.jf)
                case 0x30:  // JGE
                    pc += 1 + Int(accumulator >= operand ? inst.jt : inst.jf)
                case 0x40:  // JSET
                    pc += 1 + Int((accumulator & operand) != 0 ? inst.jt : inst.jf)
                default:
                    return nil
                }

            case 0x06:  // BPF_RET
                return inst.k

            default:
                return nil
            }
        }

        return nil
    }

    private static func writeU32(_ data: inout [UInt8], offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func readU32(_ data: [UInt8], offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
