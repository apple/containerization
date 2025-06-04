//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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
    var domain: Int32 { get }
    var type: Int32 { get }

    // Different socket types may want to expose things to do
    // before bind and listen. UDS for example may want to change
    // the permissions of the socket prior to bind/listen and also
    // possibly unlink an existing socket before bind.
    func beforeBind(fd: Int32) throws
    func beforeListen(fd: Int32) throws

    func accept(fd: Int32) throws -> (Int32, SocketType)
    func withSockAddr(_ closure: (_ ptr: UnsafePointer<sockaddr>, _ len: UInt32) throws -> Void) throws
}

extension SocketType {
    public func beforeBind(fd: Int32) {}
    public func beforeListen(fd: Int32) {}
}
