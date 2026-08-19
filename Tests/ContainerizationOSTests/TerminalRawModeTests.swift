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
import Testing

@testable import ContainerizationOS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Suite("Terminal raw mode tests")
struct TerminalRawModeTests {
    private func termiosAttributes(of descriptor: Int32) throws -> termios {
        var attrs = termios()
        try #require(tcgetattr(descriptor, &attrs) == 0, "tcgetattr failed, errno: \(errno)")
        return attrs
    }

    private func has(_ flag: tcflag_t, in attributes: termios) -> Bool {
        attributes.c_lflag & flag != 0
    }

    @Test("pty slave is in canonical mode before raw-mode setup")
    func ptySlaveIsCanonicalBeforeSetup() throws {
        let (parent, child) = try Terminal.create(initialSize: Terminal.Size(width: 120, height: 40))
        defer {
            try? parent.close()
            try? child.close()
        }

        // A freshly allocated pty slave is canonical by default (ICANON set).
        let attrs = try termiosAttributes(of: child.handle.fileDescriptor)
        #expect(has(tcflag_t(ICANON), in: attrs))
    }

    @Test("setraw clears ICANON and preserves OPOST")
    func setrawClearsCanonicalAndPreservesOutputPostProcessing() throws {
        let (parent, child) = try Terminal.create(initialSize: Terminal.Size(width: 120, height: 40))
        defer {
            try? parent.close()
            try? child.close()
        }

        try child.setraw()

        let attrs = try termiosAttributes(of: child.handle.fileDescriptor)
        #expect(!has(tcflag_t(ICANON), in: attrs), "setraw must clear canonical mode")
        #expect(attrs.c_oflag & tcflag_t(OPOST) != 0, "setraw must preserve OPOST for CRLF output translation")
    }
}
