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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#else
#error("SocketType not supported on this platform.")
#endif

/// Protocol used to describe the family of socket to be created with `Socket`.
public protocol SocketType: Sendable, CustomStringConvertible {
    /// The domain for the socket (AF_UNIX, AF_VSOCK etc.)
    var domain: Int32 { get }
    /// The type of socket (SOCK_STREAM).
    var type: Int32 { get }

    /// Actions to perform before calling bind(2).
    func beforeBind(fd: Int32) throws
    /// Actions to perform before calling listen(2).
    func beforeListen(fd: Int32) throws

    /// Handle accept(2) for an implementation of a socket type.
    func accept(fd: Int32) throws -> (Int32, SocketType)
    /// Provide a sockaddr pointer (by casting a socket specific type like sockaddr_un for example).
    func withSockAddr(_ closure: (_ ptr: UnsafePointer<sockaddr>, _ len: UInt32) throws -> Void) throws
}

extension SocketType {
    public func beforeBind(fd: Int32) {}
    public func beforeListen(fd: Int32) {}
}
