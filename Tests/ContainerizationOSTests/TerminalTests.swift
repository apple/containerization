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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("Terminal tests")
final class TerminalTests {

    @Suite("Size")
    struct SizeTests {
        @Test
        func widthAndHeightAreStored() {
            let size = Terminal.Size(width: 80, height: 24)
            #expect(size.width == 80)
            #expect(size.height == 24)
        }

        @Test
        func zeroSize() {
            let size = Terminal.Size(width: 0, height: 0)
            #expect(size.width == 0)
            #expect(size.height == 0)
        }

        @Test
        func maxValues() {
            let size = Terminal.Size(width: .max, height: .max)
            #expect(size.width == UInt16.max)
            #expect(size.height == UInt16.max)
        }
    }

    @Suite("PTY creation")
    struct CreateTests {
        @Test
        func createReturnsPair() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }
            #expect(parent.fileDescriptor >= 0)
            #expect(child.fileDescriptor >= 0)
            #expect(parent.fileDescriptor != child.fileDescriptor)
        }

        @Test
        func createWithCustomSize() throws {
            let size = Terminal.Size(width: 200, height: 50)
            let (parent, child) = try Terminal.create(initialSize: size)
            defer {
                try? parent.close()
                try? child.close()
            }
            let childSize = try child.size
            #expect(childSize.width == 200)
            #expect(childSize.height == 50)
        }

        @Test
        func createDefaultSize() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }
            let childSize = try child.size
            #expect(childSize.width == 120)
            #expect(childSize.height == 40)
        }
    }

    @Suite("Resize")
    struct ResizeTests {
        @Test
        func resizeWithSize() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            let newSize = Terminal.Size(width: 132, height: 43)
            try child.resize(size: newSize)

            let actual = try child.size
            #expect(actual.width == 132)
            #expect(actual.height == 43)
        }

        @Test
        func resizeWithWidthAndHeight() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            try child.resize(width: 100, height: 30)
            let actual = try child.size
            #expect(actual.width == 100)
            #expect(actual.height == 30)
        }

        @Test
        func resizeFromAnotherPty() throws {
            let (parent1, child1) = try Terminal.create(
                initialSize: Terminal.Size(width: 160, height: 48)
            )
            defer {
                try? parent1.close()
                try? child1.close()
            }

            let (parent2, child2) = try Terminal.create(
                initialSize: Terminal.Size(width: 80, height: 24)
            )
            defer {
                try? parent2.close()
                try? child2.close()
            }

            try child2.resize(from: child1)
            let actual = try child2.size
            #expect(actual.width == 160)
            #expect(actual.height == 48)
        }
    }

    @Suite("Write")
    struct WriteTests {
        @Test
        func writeDataToPty() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            let message = "hello\n"
            try child.write(Data(message.utf8))

            let fd = parent.fileDescriptor
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, buf.count)
            #expect(n > 0)
        }
    }

    @Suite("Terminal modes")
    struct ModeTests {
        @Test
        func setrawChangesAttributes() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            try child.setraw()

            var attr = termios()
            #expect(tcgetattr(child.fileDescriptor, &attr) == 0)
            #expect(attr.c_lflag & tcflag_t(ECHO) == 0)
            #expect(attr.c_lflag & tcflag_t(ICANON) == 0)
            // setraw also re-enables OPOST.
            #expect(attr.c_oflag & tcflag_t(OPOST) != 0)
        }

        @Test
        func disableEchoClearsFlag() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            try child.disableEcho()
            var attr = termios()
            #expect(tcgetattr(child.fileDescriptor, &attr) == 0)
            #expect(attr.c_lflag & tcflag_t(ECHO) == 0)
        }
    }

    @Suite("Close and reset")
    struct LifecycleTests {
        @Test
        func closeSucceeds() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
            }
            try child.close()
        }

        @Test
        func resetRestoresInitialState() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            // The child pty was created via openpty (setInitState: false),
            // so init it with setInitState: true to capture the original attrs.
            let term = try Terminal(descriptor: child.fileDescriptor, setInitState: true)

            // Modify the terminal.
            try term.setraw()

            // Reset and verify we get back the original state.
            try term.reset()

            var attr = termios()
            #expect(tcgetattr(child.fileDescriptor, &attr) == 0)
            #expect(attr.c_lflag & tcflag_t(ECHO) != 0)
            #expect(attr.c_lflag & tcflag_t(ICANON) != 0)
        }

        @Test
        func tryResetDoesNotThrow() throws {
            let (parent, child) = try Terminal.create()
            defer {
                try? parent.close()
                try? child.close()
            }

            let term = try Terminal(descriptor: child.fileDescriptor, setInitState: true)
            try term.setraw()
            term.tryReset()
        }
    }

    @Suite("Error")
    struct ErrorTests {
        @Test
        func notAPtyOnRegularFD() throws {
            let fd = open("/dev/null", O_RDWR)
            #expect(fd >= 0)
            defer { close(fd) }

            #expect(throws: (any Swift.Error).self) {
                try Terminal(descriptor: fd)
            }
        }

        @Test
        func notAPtyErrorDescription() {
            let error = Terminal.Error.notAPty
            #expect(error.description == "the provided fd is not a pty")
        }
    }
}
