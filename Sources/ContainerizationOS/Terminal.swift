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

/// `Terminal` provides a clean interface to deal with terminal interactions on Unix platforms.
public struct Terminal: Sendable {
    private let initState: termios?

    private var descriptor: Int32 {
        handle.fileDescriptor
    }
    public let handle: FileHandle

    public init(descriptor: Int32, setInitState: Bool = true) throws {
        if setInitState {
            self.initState = try Self.getattr(descriptor)
        } else {
            initState = nil
        }
        self.handle = .init(fileDescriptor: descriptor, closeOnDealloc: false)
    }

    /// Write the provided data to the tty device.
    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    /// The winsize for a pty.
    public struct Size: Sendable {
        let size: winsize

        /// The width or `col` of the pty.
        public var width: UInt16 {
            size.ws_col
        }
        /// The height or `rows` of the pty.
        public var height: UInt16 {
            size.ws_row
        }

        init(_ size: winsize) {
            self.size = size
        }

        /// Set the size for use with a pty.
        public init(width cols: UInt16, height rows: UInt16) {
            self.size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        }
    }

    /// Return the current pty attached to any of the STDIO descriptors.
    public static var current: Terminal {
        get throws {
            for i in [STDERR_FILENO, STDOUT_FILENO, STDIN_FILENO] {
                do {
                    return try Terminal(descriptor: i)
                } catch {}
            }
            throw Error.notAPty
        }
    }

    /// The current window size for the pty.
    public var size: Size {
        get throws {
            var ws = winsize()
            try fromSyscall(ioctl(descriptor, UInt(TIOCGWINSZ), &ws))
            return Size(ws)
        }
    }

    /// Create a new pty pair.
    /// - Parameter initialSize: An initial size of the child pty.
    public static func create(initialSize: Size? = nil) throws -> (parent: Terminal, child: Terminal) {
        var parent: Int32 = 0
        var child: Int32 = 0
        let size = initialSize ?? Size(width: 120, height: 40)
        var ws = size.size

        try fromSyscall(openpty(&parent, &child, nil, nil, &ws))
        return (
            parent: try Terminal(descriptor: parent, setInitState: false),
            child: try Terminal(descriptor: child, setInitState: false)
        )
    }
}

// MARK: Errors

extension Terminal {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notAPty

        public var description: String {
            switch self {
            case .notAPty:
                return "the provided fd is not a pty"
            }
        }
    }
}

extension Terminal {
    /// Resize the current pty from the size of the provided pty.
    ///  - Parameter pty: A pty to resize from.
    public func resize(from pty: Terminal) throws {
        var ws = try pty.size
        try fromSyscall(ioctl(descriptor, UInt(TIOCSWINSZ), &ws))
    }

    /// Resize the pty to the provided window size.
    ///  - Parameter size: A window size for a pty.
    public func resize(size: Size) throws {
        var ws = size.size
        try fromSyscall(ioctl(descriptor, UInt(TIOCSWINSZ), &ws))
    }

    /// Resize the pty to the provided window size.
    /// - Parameter width: A width or cols of the terminal.
    /// - Parameter height: A height or rows of the terminal.
    public func resize(width: UInt16, height: UInt16) throws {
        var ws = Size(width: width, height: height)
        try fromSyscall(ioctl(descriptor, UInt(TIOCSWINSZ), &ws))
    }
}

extension Terminal {
    /// Enable raw mode for the pty.
    public func setraw() throws {
        var attr = try Self.getattr(descriptor)
        cfmakeraw(&attr)
        attr.c_oflag = attr.c_oflag | tcflag_t(OPOST)
        try fromSyscall(tcsetattr(descriptor, TCSANOW, &attr))
    }

    /// Enable echo support.
    /// Chars typed will be displayed to the terminal.
    public func enableEcho() throws {
        var attr = try Self.getattr(descriptor)
        attr.c_iflag &= ~tcflag_t(ICRNL)
        attr.c_lflag &= ~tcflag_t(ICANON | ECHO)
        try fromSyscall(tcsetattr(descriptor, TCSANOW, &attr))
    }

    /// Disable echo support.
    /// Chars typed will not be displayed back to the terminal.
    public func disableEcho() throws {
        var attr = try Self.getattr(descriptor)
        attr.c_lflag &= ~tcflag_t(ECHO)
        try fromSyscall(tcsetattr(descriptor, TCSANOW, &attr))
    }

    private static func getattr(_ fd: Int32) throws -> termios {
        var attr = termios()
        try fromSyscall(tcgetattr(fd, &attr))
        return attr
    }
}

// MARK: Reset

extension Terminal {
    /// Close this pty's file descriptor.
    public func close() throws {
        do {
            // Use FileHandle's close directly as it sets the underlying fd in the object
            // to -1 for us.
            try self.handle.close()
        } catch {
            if let error = error as NSError?, error.domain == NSPOSIXErrorDomain {
                throw POSIXError(.init(rawValue: Int32(error.code))!)
            }
            throw error
        }
    }

    /// Reset the pty to its initial state.
    public func reset() throws {
        if var attr = initState {
            try fromSyscall(tcsetattr(descriptor, TCSANOW, &attr))
        }
    }

    /// Reset the pty to its initial state masking any errors.
    /// This is commonly used in a `defer` body to reset the current pty where the error code is not generally useful.
    public func tryReset() {
        try? reset()
    }
}

private func fromSyscall(_ status: Int32) throws {
    guard status == 0 else {
        throw POSIXError(.init(rawValue: errno)!)
    }
}
