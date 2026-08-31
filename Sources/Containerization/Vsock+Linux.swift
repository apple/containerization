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
import ContainerizationError
import ContainerizationOS
import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Cloud Hypervisor hybrid vsock host-side helpers
//
// Cloud Hypervisor exposes its vsock device to the host as a Unix-domain
// socket pair, not the kernel AF_VSOCK (this avoids the host needing the
// vhost-vsock kernel module).
//
// - Host → guest dials use the "base" UDS (`VsockConfig.socket`) with a
//   one-line `CONNECT <port>\n` request, answered by `OK <port>\n`. After
//   that the connection is bridged transparently.
// - Guest → host dials are accepted on per-port UDS files at the
//   conventional path `<base>_<port>` that the host pre-creates.
//
// Spec: `docs/vsock.md` in the cloud-hypervisor repository.

/// Returns the conventional per-port UDS path for guest→host vsock connections,
/// derived by suffixing the base socket path with `_<port>`.
func chVsockListenSocketPath(baseSocket: URL, port: UInt32) -> URL {
    URL(fileURLWithPath: "\(baseSocket.path)_\(port)")
}

/// Bind + listen a fresh AF_UNIX SOCK_STREAM at `path`, unlinking any stale
/// socket file at that path first. Returns the listening fd; ownership is
/// transferred to the caller.
///
/// The socket file is created with mode `perms` (default `0o600`). The
/// per-VM workDir already restricts access via its own `0o700` mode, but
/// tightening the socket itself is cheap defense-in-depth — vminitd's gRPC
/// surface trusts whoever can `connect(2)` and exposes full container
/// control, so any local-user reach into these sockets is a privilege
/// escalation primitive.
func chVsockBindListener(at path: URL, perms: mode_t = 0o600) throws -> Int32 {
    let unix = try UnixType(path: path.path, perms: perms, unlinkExisting: true)
    let socket = try Socket(type: unix, closeOnDeinit: false)
    do {
        try socket.listen()
    } catch {
        try? socket.close()
        throw error
    }
    return socket.fileDescriptor
}

/// Dial guest port `port` over the cloud-hypervisor hybrid vsock at
/// `baseSocket`. Returns a `FileHandle` wrapping the connected fd; the
/// FileHandle does **not** close the fd on deinit — ownership of the fd
/// transfers to the caller (typically `Vminitd.init`, which hands it to
/// NIO via `withConnectedSocket`; NIO is then responsible for closing it
/// when the channel is torn down). Callers using the FileHandle directly
/// must close the underlying fd themselves.
func chVsockDial(baseSocket: URL, port: UInt32) async throws -> FileHandle {
    try await Task.detached {
        try chVsockDialSync(baseSocket: baseSocket, port: port)
    }.value
}

// MARK: - Internals

private func chVsockDialSync(baseSocket: URL, port: UInt32) throws -> FileHandle {
    let unix = try UnixType(path: baseSocket.path)
    let socket = try Socket(type: unix, closeOnDeinit: false)

    do {
        try socket.connect()
        // Bound the bootstrap reply read so a hung cloud-hypervisor muxer
        // can't pin this thread forever. CH replies within milliseconds in
        // healthy operation; 30 s is well outside that and matches the
        // CloudHypervisor REST client default. After bootstrap the fd is
        // handed to NIO which puts it in non-blocking mode, where
        // SO_RCVTIMEO has no effect — so leaving the timeout in place is
        // harmless.
        try socket.setTimeout(option: .receive, seconds: 30)
        let request = "CONNECT \(port)\n"
        _ = try socket.write(data: Data(request.utf8))
        let response = try readLine(fd: socket.fileDescriptor)
        // Cloud Hypervisor responds with "OK <local-port>\n" where
        // <local-port> is the local-side port the muxer allocated for this
        // forwarded connection — NOT the peer port we asked for. So we just
        // require the response to start with "OK " and parse a UInt32 after.
        guard response.hasPrefix("OK "),
            UInt32(response.dropFirst(3)) != nil
        else {
            throw ContainerizationError(
                .invalidState,
                message: "unexpected vsock CONNECT response: \(response.debugDescription)"
            )
        }
        return FileHandle(fileDescriptor: socket.fileDescriptor, closeOnDealloc: false)
    } catch {
        try? socket.close()
        throw error
    }
}

/// Read CH's hybrid-vsock `CONNECT` reply line (`OK <local-port>\n`) one
/// byte at a time. Reads from `fd` until a `\n` is seen or `maxLength` is
/// reached; the returned string excludes the terminating newline. We do
/// this by hand because the fd is still in blocking mode (NIO takes over
/// only after the bootstrap completes) and there's no Foundation /
/// NIO line reader that operates on a raw blocking POSIX fd.
private func readLine(fd: Int32, maxLength: Int = 256) throws -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(maxLength)
    while bytes.count < maxLength {
        var byte: UInt8 = 0
        let n = withUnsafeMutablePointer(to: &byte) { ptr -> ssize_t in
            read(fd, ptr, 1)
        }
        if n == 0 {
            break
        }
        if n < 0 {
            let savedErrno = errno
            // SO_RCVTIMEO expiry surfaces as EAGAIN / EWOULDBLOCK on a
            // blocking socket. Translate to a clear timeout error so callers
            // don't have to inspect errno.
            if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK {
                throw ContainerizationError(
                    .timeout,
                    message: "vsock CONNECT response not received within socket receive timeout"
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        if byte == UInt8(ascii: "\n") {
            break
        }
        bytes.append(byte)
    }
    return String(decoding: bytes, as: UTF8.self)
}
#endif
