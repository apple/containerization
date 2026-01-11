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

extension BinaryInteger {
    private func toUnsignedMemoryAmount(_ amount: UInt64) -> UInt64 {
        guard self >= 0 else {
            fatalError("encountered negative number during conversion to memory amount")
        }
        let val = UInt64(self)
        let (newVal, overflow) = val.multipliedReportingOverflow(by: amount)
        guard !overflow else {
            fatalError("UInt64 overflow when converting to memory amount")
        }
        return newVal
    }

    public func kib() -> UInt64 {
        self.toUnsignedMemoryAmount(1 << 10)
    }

    public func mib() -> UInt64 {
        self.toUnsignedMemoryAmount(1 << 20)
    }

    public func gib() -> UInt64 {
        self.toUnsignedMemoryAmount(1 << 30)
    }

    public func tib() -> UInt64 {
        self.toUnsignedMemoryAmount(1 << 40)
    }

    public func pib() -> UInt64 {
        self.toUnsignedMemoryAmount(1 << 50)
    }
}
