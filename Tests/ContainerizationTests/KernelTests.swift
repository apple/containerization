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

//

import Foundation
import Testing

@testable import Containerization

final class KernelTests {
    @Test func kernelArgs() {
        let commandLine = Kernel.CommandLine(debug: false, panic: 0)
        let kernel = Kernel(path: .init(fileURLWithPath: ""), platform: .linuxArm, commandline: commandLine)

        let expected = "console=hvc0 tsc=reliable panic=0"
        let cmdline = kernel.commandLine.kernelArgs.joined(separator: " ")
        #expect(cmdline == expected)
    }

    @Test func kernelDebugArgs() {
        let cmdLine = Kernel.CommandLine(debug: true, panic: 0)
        let kernel = Kernel(path: .init(fileURLWithPath: ""), platform: .linuxArm, commandline: cmdLine)

        let expected = "console=hvc0 tsc=reliable debug panic=0"
        let cmdline = kernel.commandLine.kernelArgs.joined(separator: " ")
        #expect(cmdline == expected)
    }

    @Test func kernelCommandLineInitWithDebugTrue() {
        let commandLine = Kernel.CommandLine(debug: true, panic: 5, initArgs: ["--verbose"])

        #expect(commandLine.kernelArgs == ["console=hvc0", "tsc=reliable", "debug", "panic=5"])
        #expect(commandLine.initArgs == ["--verbose"])
    }

    @Test func kernelCommandLineMutatingMethods() {
        var commandLine = Kernel.CommandLine(kernelArgs: ["console=hvc0"], initArgs: [])

        commandLine.addDebug()
        commandLine.addPanic(level: 10)

        #expect(commandLine.kernelArgs == ["console=hvc0", "debug", "panic=10"])
    }
}
