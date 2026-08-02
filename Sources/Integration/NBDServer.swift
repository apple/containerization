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

import ContainerizationError
import Foundation
import Logging
import NIOCore
import NIOPosix

#if os(macOS)
/// A minimal NBD server for integration testing.
///
/// Serves a file-backed block device using the NBD newstyle handshake protocol.
/// Supports both TCP and Unix domain socket transports.
final class NBDServer: Sendable {
    private let channel: Channel
    private let socketPath: String?
    private let group: EventLoopGroup
    let url: String

    private let store: NBDBackingStore

    init(store: NBDBackingStore, socketPath: String, logger: Logger? = nil) throws {
        self.socketPath = socketPath
        self.store = store
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        try? FileManager.default.removeItem(atPath: socketPath)

        self.channel = try Self.bootstrap(group: self.group, store: store, logger: logger)
            .bind(unixDomainSocketPath: socketPath)
            .wait()
        self.url = "nbd+unix:///?socket=\(socketPath)"
    }

    init(store: NBDBackingStore, port: Int, logger: Logger? = nil) throws {
        self.socketPath = nil
        self.store = store
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        self.channel = try Self.bootstrap(group: self.group, store: store, logger: logger)
            .bind(host: "127.0.0.1", port: port)
            .wait()

        guard let boundPort = channel.localAddress?.port, boundPort > 0 else {
            throw ContainerizationError(.internalError, message: "NBD server failed to bind to a port")
        }
        self.url = "nbd://127.0.0.1:\(boundPort)"
    }

    convenience init(filePath: String, socketPath: String, logger: Logger? = nil) throws {
        try self.init(store: Self.fileStore(filePath), socketPath: socketPath, logger: logger)
    }

    convenience init(filePath: String, port: Int, logger: Logger? = nil) throws {
        try self.init(store: Self.fileStore(filePath), port: port, logger: logger)
    }

    private static func fileStore(_ path: String) throws -> NBDBackingStore {
        guard let store = NBDFileStore(path: path) else {
            throw ContainerizationError(.internalError, message: "NBD server failed to open \(path)")
        }
        return store
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
        self.store.close()
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private static func bootstrap(group: EventLoopGroup, store: NBDBackingStore, logger: Logger?) -> ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NBDConnectionHandler(store: store, logger: logger)
                    )
                }
            }
    }
}

private final class NBDConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    // Protocol constants
    static let magic: UInt64 = 0x4e42_444d_4147_4943
    static let ihaveopt: UInt64 = 0x4948_4156_454f_5054
    static let replyMagic: UInt64 = 0x3_e889_0455_65a9
    static let requestMagic: UInt32 = 0x2560_9513
    static let simpleReplyMagic: UInt32 = 0x6744_6698

    static let optExportName: UInt32 = 1
    static let optAbort: UInt32 = 2
    static let optInfo: UInt32 = 6
    static let optGo: UInt32 = 7

    static let cmdRead: UInt16 = 0
    static let cmdWrite: UInt16 = 1
    static let cmdDisc: UInt16 = 2
    static let cmdFlush: UInt16 = 3
    static let cmdTrim: UInt16 = 4
    static let cmdCache: UInt16 = 5
    static let cmdWriteZeroes: UInt16 = 6

    /// Command flags travel in the two bytes after the request magic.
    /// https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md
    static let cmdFlagFUA: UInt16 = 0x1
    static let cmdFlagNoHole: UInt16 = 0x2

    static let flagFixedNewstyle: UInt16 = 0x1
    static let flagNoZeroes: UInt16 = 0x2
    static let clientFlagFixedNewstyle: UInt32 = 0x1
    static let clientFlagNoZeroes: UInt32 = 0x2
    static let transmitHasFlags: UInt16 = 0x1
    static let transmitSendFlush: UInt16 = 0x4
    static let transmitSendFUA: UInt16 = 0x8
    /// A client is not allowed to send a trim without being told the server
    /// takes them, so an export that never sets this is never asked to let
    /// anything go, however much the guest has finished with.
    /// https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md
    static let transmitSendTrim: UInt16 = 0x20
    static let transmitReadOnly: UInt16 = 0x2
    static let transmitSendWriteZeroes: UInt16 = 0x40
    static let transmitSendCache: UInt16 = 0x400

    static let repACK: UInt32 = 1
    static let repInfo: UInt32 = 3
    static let repErrUnsup: UInt32 = 0x8000_0001
    static let infoExport: UInt16 = 0
    static let infoBlockSize: UInt16 = 3

    // NBD error codes
    static let errOK: UInt32 = 0
    static let errPerm: UInt32 = 1
    static let errIO: UInt32 = 5
    static let errNoMem: UInt32 = 12
    static let errInval: UInt32 = 22
    static let errNoSpc: UInt32 = 28
    static let errOverflow: UInt32 = 75
    static let errNotsup: UInt32 = 95
    static let errShutdown: UInt32 = 108

    private let store: NBDBackingStore
    private let fileSize: UInt64
    private let logger: Logger?
    private var buffer: ByteBuffer = ByteBuffer()
    private var state: ConnectionState = .handshake

    private enum ConnectionState {
        case handshake
        case options(noZeroes: Bool)
        case transmission
    }

    init(store: NBDBackingStore, logger: Logger?) {
        self.store = store
        self.fileSize = store.size
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        guard fileSize > 0 else {
            context.close(promise: nil)
            return
        }
        // Send initial handshake.
        var buf = context.channel.allocator.buffer(capacity: 18)
        buf.writeInteger(Self.magic)
        buf.writeInteger(Self.ihaveopt)
        buf.writeInteger(Self.flagFixedNewstyle | Self.flagNoZeroes)
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Every connection to an export serves the one store behind it, so a
        // client going away is not what ends it. The server closes it instead.
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        processBuffer(context: context)
    }

    private func processBuffer(context: ChannelHandlerContext) {
        while true {
            switch state {
            case .handshake:
                guard buffer.readableBytes >= 4,
                    let clientFlags = buffer.readInteger(as: UInt32.self)
                else {
                    return
                }
                guard clientFlags & Self.clientFlagFixedNewstyle != 0 else {
                    context.close(promise: nil)
                    return
                }
                let noZeroes = clientFlags & Self.clientFlagNoZeroes != 0
                state = .options(noZeroes: noZeroes)

            case .options(let noZeroes):
                guard buffer.readableBytes >= 16 else {
                    return
                }
                // Peek at the header without consuming.
                let readerIndex = buffer.readerIndex
                guard let magic = buffer.getInteger(at: readerIndex, as: UInt64.self),
                    let optType = buffer.getInteger(at: readerIndex + 8, as: UInt32.self),
                    let dataLen = buffer.getInteger(at: readerIndex + 12, as: UInt32.self)
                else {
                    context.close(promise: nil)
                    return
                }

                // Wait until we have the full option data.
                guard buffer.readableBytes >= 16 + Int(dataLen) else {
                    return
                }
                // Consume the header.
                buffer.moveReaderIndex(forwardBy: 16)

                guard magic == Self.ihaveopt else {
                    context.close(promise: nil)
                    return
                }

                var transmitFlags =
                    Self.transmitHasFlags | Self.transmitSendFlush | Self.transmitSendFUA
                    | Self.transmitSendTrim | Self.transmitSendWriteZeroes | Self.transmitSendCache
                if store.isReadOnly {
                    transmitFlags |= Self.transmitReadOnly
                }

                switch optType {
                case Self.optExportName:
                    if dataLen > 0 {
                        buffer.moveReaderIndex(forwardBy: Int(dataLen))
                    }
                    var reply = context.channel.allocator.buffer(capacity: 10)
                    reply.writeInteger(fileSize)
                    reply.writeInteger(transmitFlags)
                    if !noZeroes {
                        reply.writeRepeatingByte(0, count: 124)
                    }
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                    state = .transmission

                case Self.optInfo, Self.optGo:
                    // Parse InfoRequest to check for block size request.
                    var requestedBlockSize = false
                    if dataLen >= 6 {
                        let optDataStart = buffer.readerIndex
                        let nameLen = Int(buffer.getInteger(at: optDataStart, as: UInt32.self) ?? 0)
                        let infoOffset = optDataStart + 4 + nameLen
                        if infoOffset + 2 <= optDataStart + Int(dataLen) {
                            let numReqs = Int(buffer.getInteger(at: infoOffset, as: UInt16.self) ?? 0)
                            for i in 0..<numReqs {
                                let reqOffset = infoOffset + 2 + i * 2
                                if reqOffset + 2 <= optDataStart + Int(dataLen) {
                                    let infoType = buffer.getInteger(at: reqOffset, as: UInt16.self) ?? 0
                                    if infoType == Self.infoBlockSize {
                                        requestedBlockSize = true
                                    }
                                }
                            }
                        }
                    }
                    if dataLen > 0 {
                        buffer.moveReaderIndex(forwardBy: Int(dataLen))
                    }

                    // Send NBD_INFO_EXPORT reply.
                    var exportInfo = context.channel.allocator.buffer(capacity: 32)
                    writeOptReply(&exportInfo, optType: optType, replyType: Self.repInfo, dataLen: 12)
                    exportInfo.writeInteger(Self.infoExport)
                    exportInfo.writeInteger(fileSize)
                    exportInfo.writeInteger(transmitFlags)

                    // Send NBD_INFO_BLOCK_SIZE if requested.
                    if requestedBlockSize {
                        writeOptReply(&exportInfo, optType: optType, replyType: Self.repInfo, dataLen: 14)
                        exportInfo.writeInteger(Self.infoBlockSize)
                        exportInfo.writeInteger(UInt32(1))  // minimum
                        exportInfo.writeInteger(UInt32(4096))  // preferred
                        exportInfo.writeInteger(UInt32(4096 * 32))  // maximum
                    }

                    writeOptReply(&exportInfo, optType: optType, replyType: Self.repACK, dataLen: 0)
                    context.writeAndFlush(wrapOutboundOut(exportInfo), promise: nil)

                    if optType == Self.optGo {
                        state = .transmission
                    }

                case Self.optAbort:
                    if dataLen > 0 {
                        buffer.moveReaderIndex(forwardBy: Int(dataLen))
                    }
                    context.close(promise: nil)
                    return

                default:
                    if dataLen > 0 {
                        buffer.moveReaderIndex(forwardBy: Int(dataLen))
                    }
                    var reply = context.channel.allocator.buffer(capacity: 20)
                    writeOptReply(&reply, optType: optType, replyType: Self.repErrUnsup, dataLen: 0)
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                }

            case .transmission:
                // Request header: 4 magic + 2 flags + 2 type + 8 cookie + 8 offset + 4 length = 28
                guard buffer.readableBytes >= 28 else {
                    return
                }
                let readerIndex = buffer.readerIndex
                guard let magic = buffer.getInteger(at: readerIndex, as: UInt32.self),
                    let cmdFlags = buffer.getInteger(at: readerIndex + 4, as: UInt16.self),
                    let cmdType = buffer.getInteger(at: readerIndex + 6, as: UInt16.self),
                    let cookie = buffer.getInteger(at: readerIndex + 8, as: UInt64.self),
                    let offset = buffer.getInteger(at: readerIndex + 16, as: UInt64.self),
                    let length = buffer.getInteger(at: readerIndex + 24, as: UInt32.self)
                else {
                    context.close(promise: nil)
                    return
                }
                guard magic == Self.requestMagic else {
                    context.close(promise: nil)
                    return
                }

                /// A command that has been dealt with, but whose reply the
                /// protocol holds back until what it wrote is durable when the
                /// client asked for that.
                func replyHonouringFUA(_ error: UInt32) {
                    if cmdFlags & Self.cmdFlagFUA != 0 && error == Self.errOK {
                        store.flush()
                    }
                    var reply = context.channel.allocator.buffer(capacity: 16)
                    writeSimpleReply(&reply, cookie: cookie, error: error)
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                }

                // An export that only reads turns away everything that writes,
                // and a request reaching past the end of one is refused rather
                // than passed to the store to fail on.
                let writes =
                    cmdType == Self.cmdWrite || cmdType == Self.cmdTrim
                    || cmdType == Self.cmdWriteZeroes
                let addressed =
                    cmdType == Self.cmdRead || cmdType == Self.cmdWrite || cmdType == Self.cmdTrim
                    || cmdType == Self.cmdWriteZeroes || cmdType == Self.cmdCache
                if writes && store.isReadOnly {
                    if cmdType == Self.cmdWrite {
                        // A refused write is consumed whole, so its payload is
                        // never read back as the next request's header; the
                        // refusal waits alongside the acceptance for all of it.
                        guard buffer.readableBytes >= 28 + Int(length) else {
                            return
                        }
                        buffer.moveReaderIndex(forwardBy: 28 + Int(length))
                    } else {
                        buffer.moveReaderIndex(forwardBy: 28)
                    }
                    replyHonouringFUA(Self.errPerm)
                    continue
                }
                if addressed && !store.covers(offset: offset, length: Int(length)) {
                    if cmdType == Self.cmdWrite {
                        guard buffer.readableBytes >= 28 + Int(length) else {
                            return
                        }
                        buffer.moveReaderIndex(forwardBy: 28 + Int(length))
                    } else {
                        buffer.moveReaderIndex(forwardBy: 28)
                    }
                    replyHonouringFUA(Self.errInval)
                    continue
                }

                switch cmdType {
                case Self.cmdWrite:
                    // Need the full write payload before processing.
                    guard buffer.readableBytes >= 28 + Int(length) else {
                        return
                    }
                    buffer.moveReaderIndex(forwardBy: 28)
                    var writeData = [UInt8](repeating: 0, count: Int(length))
                    buffer.readWithUnsafeReadableBytes { ptr in
                        writeData.withUnsafeMutableBytes { dst in
                            guard let dstBase = dst.baseAddress, let srcBase = ptr.baseAddress else {
                                return
                            }
                            _ = memcpy(dstBase, srcBase, Int(length))
                        }
                        return Int(length)
                    }
                    let stored = store.write(offset: offset, data: writeData)
                    replyHonouringFUA(stored ? Self.errOK : Self.errIO)

                case Self.cmdRead:
                    buffer.moveReaderIndex(forwardBy: 28)
                    let readBuf = store.read(offset: offset, length: Int(length))
                    var reply = context.channel.allocator.buffer(capacity: 16 + Int(length))
                    writeSimpleReply(&reply, cookie: cookie, error: readBuf == nil ? Self.errIO : Self.errOK)
                    if let readBuf {
                        reply.writeBytes(readBuf)
                    }
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)

                case Self.cmdDisc:
                    buffer.moveReaderIndex(forwardBy: 28)
                    context.close(promise: nil)
                    return

                case Self.cmdFlush:
                    buffer.moveReaderIndex(forwardBy: 28)
                    store.flush()
                    var reply = context.channel.allocator.buffer(capacity: 16)
                    writeSimpleReply(&reply, cookie: cookie, error: Self.errOK)
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)

                case Self.cmdTrim:
                    buffer.moveReaderIndex(forwardBy: 28)
                    let released = store.discard(offset: offset, length: Int(length))
                    replyHonouringFUA(released ? Self.errOK : Self.errIO)

                case Self.cmdWriteZeroes:
                    buffer.moveReaderIndex(forwardBy: 28)
                    // Discarding leaves zeroes behind and costs nothing, so it
                    // serves unless the client has said it wants the range to
                    // stay written through, which is what the flag is for.
                    let zeroed: Bool
                    if cmdFlags & Self.cmdFlagNoHole != 0 {
                        zeroed = store.write(
                            offset: offset, data: [UInt8](repeating: 0, count: Int(length)))
                    } else {
                        zeroed = store.discard(offset: offset, length: Int(length))
                    }
                    replyHonouringFUA(zeroed ? Self.errOK : Self.errIO)

                case Self.cmdCache:
                    // A hint that a range is wanted soon. Every store here
                    // answers a read in the same time whether it was told or
                    // not, so there is nothing to prepare.
                    buffer.moveReaderIndex(forwardBy: 28)
                    replyHonouringFUA(Self.errOK)

                default:
                    buffer.moveReaderIndex(forwardBy: 28)
                    var reply = context.channel.allocator.buffer(capacity: 16)
                    writeSimpleReply(&reply, cookie: cookie, error: Self.errNotsup)
                    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
                }
            }
        }
    }

    private func writeOptReply(_ buf: inout ByteBuffer, optType: UInt32, replyType: UInt32, dataLen: UInt32) {
        buf.writeInteger(Self.replyMagic)
        buf.writeInteger(optType)
        buf.writeInteger(replyType)
        buf.writeInteger(dataLen)
    }

    private func writeSimpleReply(_ buf: inout ByteBuffer, cookie: UInt64, error: UInt32) {
        buf.writeInteger(Self.simpleReplyMagic)
        buf.writeInteger(error)
        buf.writeInteger(cookie)
    }
}
#endif
