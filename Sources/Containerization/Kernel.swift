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

import Foundation

/// An object representing a Linux kernel used to boot a virtual machine.
/// In addition to a path to the kernel itself, this type stores relevant
/// data such as the commandline to pass to the kernel, and init arguments.
public struct Kernel: Sendable, Codable {
    /// The command line arguments passed to the kernel on boot.
    public struct CommandLine: Sendable, Codable {
        public static let kernelDefaults = [
            "console=hvc0",
            "tsc=reliable",
        ]

        /// Adds the debug argument to the kernel commandline.
        mutating public func addDebug() {
            self.kernelArgs.append("debug")
        }

        /// Adds a panic level to the kernel commandline.
        mutating public func addPanic(level: Int) {
            self.kernelArgs.append("panic=\(level)")
        }

        /// Additional kernel arguments.
        public var kernelArgs: [String]
        /// Additional arguments passed to the Initial Process / Agent.
        public var initArgs: [String]

        /// Initializes the kernel commandline using the mix of kernel arguments
        /// and init arguments.
        public init(
            kernelArgs: [String] = kernelDefaults,
            initArgs: [String] = []
        ) {
            self.kernelArgs = kernelArgs
            self.initArgs = initArgs
        }

        /// Initializes the kernel commandline to the defaults of Self.kernelDefaults,
        /// adds a debug and panic flag as instructed, and optionally a set of init
        /// process flags to supply to vminitd.
        public init(debug: Bool, panic: Int, initArgs: [String] = []) {
            var args = Self.kernelDefaults
            if debug {
                args.append("debug")
            }
            args.append("panic=\(panic)")
            self.kernelArgs = args
            self.initArgs = initArgs
        }
    }

    /// Path on disk to the kernel binary.
    public var path: URL
    /// Platform for the kernel.
    public var platform: SystemPlatform
    /// Kernel and init process command line.
    public var commandLine: Self.CommandLine

    /// Kernel command line arguments.
    public var kernelArgs: [String] {
        self.commandLine.kernelArgs
    }

    /// Init process arguments.
    public var initArgs: [String] {
        self.commandLine.initArgs
    }

    public init(
        path: URL,
        platform: SystemPlatform,
        commandline: Self.CommandLine = CommandLine(debug: false, panic: 0)
    ) {
        self.path = path
        self.platform = platform
        self.commandLine = commandline
    }
}
