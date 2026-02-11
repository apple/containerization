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

import CShim
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
private let _kill = Darwin.kill
#elseif canImport(Musl)
import Musl
private let _kill = Musl.kill
#elseif canImport(Glibc)
import Glibc
private let _kill = Glibc.kill
#endif

/// Use a command to run an executable.
public struct Command: Sendable {
    /// Path to the executable binary.
    public var executable: String
    /// Arguments provided to the binary.
    public var arguments: [String]
    /// Environment variables for the process.
    public var environment: [String]
    /// The directory where the process should execute.
    public var directory: String?
    /// Additional files to pass to the process.
    public var extraFiles: [FileHandle]
    /// The standard input.
    public var stdin: FileHandle?
    /// The standard output.
    public var stdout: FileHandle?
    /// The standard error.
    public var stderr: FileHandle?

    private let state: State

    /// System level attributes to set on the process.
    public struct Attrs: Sendable {
        /// Set pgroup for the new process.
        public var setPGroup: Bool
        /// Inherit the real uid/gid of the parent.
        public var resetIDs: Bool
        /// Reset the child's signal handlers to the default.
        public var setSignalDefault: Bool
        /// The initial signal mask for the process.
        public var signalMask: UInt32
        /// Create a new session for the process.
        public var setsid: Bool
        /// Set the controlling terminal for the process to fd 0.
        public var setctty: Bool
        /// Set the process user ID.
        public var uid: UInt32?
        /// Set the process group ID.
        public var gid: UInt32?
        /// Signal to send when parent process dies (Linux only).
        public var pdeathSignal: Int32?

        public init(
            setPGroup: Bool = false,
            resetIDs: Bool = false,
            setSignalDefault: Bool = true,
            signalMask: UInt32 = 0,
            setsid: Bool = false,
            setctty: Bool = false,
            uid: UInt32? = nil,
            gid: UInt32? = nil,
            pdeathSignal: Int32? = nil
        ) {
            self.setPGroup = setPGroup
            self.resetIDs = resetIDs
            self.setSignalDefault = setSignalDefault
            self.signalMask = signalMask
            self.setsid = setsid
            self.setctty = setctty
            self.uid = uid
            self.gid = gid
            self.pdeathSignal = pdeathSignal
        }
    }

    private final class State: Sendable {
        let pid: Atomic<pid_t> = Atomic(-1)
    }

    /// Attributes to set on the process.
    public var attrs = Attrs()

    /// System level process identifier.
    public var pid: Int32 { self.state.pid.load(ordering: .acquiring) }

    public init(
        _ executable: String,
        arguments: [String] = [],
        environment: [String] = environment(),
        directory: String? = nil,
        extraFiles: [FileHandle] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.extraFiles = extraFiles
        self.directory = directory
        self.state = State()
    }

    public static func environment() -> [String] {
        ProcessInfo.processInfo.environment
            .map { "\($0)=\($1)" }
    }
}

extension Command {
    public enum Error: Swift.Error, CustomStringConvertible {
        case processRunning

        public var description: String {
            switch self {
            case .processRunning:
                return "the process is already running"
            }
        }
    }
}

extension Command {
    @discardableResult
    public func kill(_ signal: Int32) -> Int32? {
        let pid = self.pid
        guard pid > 0 else {
            return nil
        }
        return _kill(pid, signal)
    }
}

extension Command {
    /// Start the process.
    public func start() throws {
        guard self.pid == -1 else {
            throw Error.processRunning
        }
        let child = try execute()
        self.state.pid.store(child, ordering: .releasing)
    }

    /// Wait for the process to exit and return the exit status.
    @discardableResult
    public func wait() throws -> Int32 {
        var rus = rusage()
        var ws = Int32()

        let pid = self.pid
        guard pid > 0 else {
            return -1
        }

        let result = wait4(pid, &ws, 0, &rus)
        guard result == pid else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return Self.toExitStatus(ws)
    }

    private func execute() throws -> pid_t {
        var attrs = exec_command_attrs()
        exec_command_attrs_init(&attrs)

        let set = try createFileset()
        defer {
            for nullHandle in set.nullHandles {
                try? nullHandle.close()
            }
        }
        var fds = [Int32](repeating: 0, count: set.handles.count)
        for (i, handle) in set.handles.enumerated() {
            fds[i] = handle.fileDescriptor
        }

        attrs.setsid = self.attrs.setsid ? 1 : 0
        attrs.setctty = self.attrs.setctty ? 1 : 0
        attrs.setpgid = self.attrs.setPGroup ? 1 : 0

        var cwdPath: UnsafeMutablePointer<CChar>?
        if let chdir = self.directory {
            cwdPath = strdup(chdir)
        }
        defer {
            if let cwdPath {
                free(cwdPath)
            }
        }

        if let uid = self.attrs.uid {
            attrs.uid = uid
        }
        if let gid = self.attrs.gid {
            attrs.gid = gid
        }

        if let pdeathSignal = self.attrs.pdeathSignal {
            attrs.pdeathSignal = pdeathSignal
        }

        var pid: pid_t = 0
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for arg in argv where arg != nil {
                free(arg)
            }
        }

        let env = environment.map { strdup($0) } + [nil]
        defer {
            for e in env where e != nil {
                free(e)
            }
        }

        let result = fds.withUnsafeBufferPointer { file_handles in
            exec_command(
                &pid,
                argv[0],
                &argv,
                env,
                file_handles.baseAddress!, Int32(file_handles.count),
                cwdPath ?? nil,
                &attrs)
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        return pid
    }

    /// Create a posix_spawn file actions set of fds to pass to the new process
    private func createFileset() throws -> (nullHandles: [FileHandle], handles: [FileHandle]) {
        // grab dev null handles for different purposes
        let nullRead = try openDevNull(flags: O_RDONLY)
        let nullWrite = try openDevNull(flags: O_WRONLY)
        var files = [FileHandle]()
        files.append(stdin ?? nullRead)
        files.append(stdout ?? nullWrite)
        files.append(stderr ?? nullWrite)
        files.append(contentsOf: extraFiles)
        return (nullHandles: [nullRead, nullWrite], handles: files)
    }

    /// Returns a file handle to /dev/null with the specified flags.
    private func openDevNull(flags: Int32) throws -> FileHandle {
        let fd = open("/dev/null", flags, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }
}

extension Command {
    private static let signalOffset: Int32 = 128

    private static let shift: Int32 = 8
    private static let mask: Int32 = 0x7F
    private static let stopped: Int32 = 0x7F
    private static let exited: Int32 = 0x00

    static func signaled(_ ws: Int32) -> Bool {
        ws & mask != stopped && ws & mask != exited
    }

    static func exited(_ ws: Int32) -> Bool {
        ws & mask == exited
    }

    static func exitStatus(_ ws: Int32) -> Int32 {
        let r: Int32
        #if os(Linux)
        r = ws >> shift & 0xFF
        #else
        r = ws >> shift
        #endif
        return r
    }

    public static func toExitStatus(_ ws: Int32) -> Int32 {
        if signaled(ws) {
            // We use the offset as that is how existing container
            // runtimes minic bash for the status when signaled.
            return Int32(Self.signalOffset + ws & mask)
        }
        if exited(ws) {
            return exitStatus(ws)
        }
        return ws
    }

}

private func WIFEXITED(_ status: Int32) -> Bool {
    _WSTATUS(status) == 0
}

private func _WSTATUS(_ status: Int32) -> Int32 {
    status & 0x7f
}

private func WIFSIGNALED(_ status: Int32) -> Bool {
    (_WSTATUS(status) != 0) && (_WSTATUS(status) != 0x7f)
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func WTERMSIG(_ status: Int32) -> Int32 {
    status & 0x7f
}
