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

import ContainerizationOS
import Foundation

/// Exit status information for a container process
struct ContainerExitStatus: Sendable {
    var exitCode: Int32
    var exitedAt: Date
}

/// Protocol for managing container processes
///
/// This protocol abstracts the underlying container runtime implementation,
/// allowing for different backends like vmexec or runc.
protocol ContainerProcess: Sendable {
    /// Unique identifier for the container process
    var id: String { get }

    /// Process ID of the running container (nil if not started)
    var pid: Int32? { get }

    /// Start the container process
    /// - Returns: The process ID of the started container
    /// - Throws: If the process fails to start
    func start() async throws -> Int32

    /// Wait for the container process to exit
    /// - Returns: Exit status information when the process exits
    func wait() async -> ContainerExitStatus

    /// Send a signal to the container process
    /// - Parameter signal: The signal number to send
    /// - Throws: If the signal cannot be sent
    func kill(_ signal: Int32) async throws

    /// Resize the terminal for the container process
    /// - Parameter size: The new terminal size
    /// - Throws: If the terminal cannot be resized or process doesn't have a terminal
    func resize(size: Terminal.Size) throws

    /// Close stdin for the container process
    /// - Throws: If stdin cannot be closed
    func closeStdin() throws

    /// Delete the container process and cleanup resources
    /// - Throws: If cleanup fails
    func delete() async throws

    /// Set the exit status of the process.
    func setExit(_ status: Int32)
}
