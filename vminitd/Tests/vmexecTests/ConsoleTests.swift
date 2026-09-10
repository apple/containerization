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

#if os(Linux)

import Glibc
import Testing
@testable import vmexec

@Suite("vmexec Console")
struct ConsoleTests {
    @Test("configureStdIO preserves output larger than the tty buffer")
    func configureStdIOPreservesLargeOutput() throws {
        let console = try Console()
        defer { try? console.close() }

        let expected = [UInt8](repeating: 0x61, count: 4096)
        let child = fork()
        #expect(child >= 0)
        guard child >= 0 else { return }

        if child == 0 {
            do {
                try console.configureStdIO()
                expected.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { _exit(1) }
                    var written = 0
                    while written < bytes.count {
                        let result = Glibc.write(
                            STDOUT_FILENO,
                            baseAddress.advanced(by: written),
                            bytes.count - written
                        )
                        guard result > 0 else { _exit(1) }
                        written += result
                    }
                    _exit(0)
                }
            } catch {
                _exit(1)
            }
        }

        var received: [UInt8] = []
        received.reserveCapacity(expected.count)
        while received.count < expected.count {
            var descriptor = pollfd(fd: console.master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 5_000)
            #expect(ready >= 0)
            guard ready > 0 else { break }

            var buffer = [UInt8](repeating: 0, count: 1024)
            let result = buffer.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Glibc.read(console.master, baseAddress, bytes.count)
            }
            if result > 0 {
                received.append(contentsOf: buffer.prefix(Int(result)))
            } else if result == -1 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        var status: Int32 = 0
        #expect(waitpid(child, &status, 0) == child)
        #expect((status & 0x7f) == 0)
        #expect(((status >> 8) & 0xff) == 0)
        #expect(received == expected)
    }
}

#endif
