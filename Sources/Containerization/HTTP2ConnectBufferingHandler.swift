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
import GRPCCore
import GRPCNIOTransportCore
import NIOCore
import NIOPosix

/// Buffers incoming bytes until the full gRPC HTTP/2 pipeline is configured, then replays them.
///
/// This prevents the race condition where the vminitd server's initial HTTP/2 SETTINGS frame
/// arrives and is discarded before `configureGRPCClientPipeline` has finished installing
/// `ClientConnectionHandler`.
///
/// The handler is added via `ClientBootstrap.channelInitializer`, which runs before
/// `registerAlreadyConfigured0` adds the fd to epoll/kqueue — guaranteeing it is in place
/// before any bytes can arrive on the socket.
///
/// When `NIOHTTP2Handler` is added to the pipeline (inside `configureGRPCClientPipeline`), its
/// `handlerAdded` fires an outbound flush (the HTTP/2 client preface). We intercept that flush
/// and schedule a deferred removal via the event loop. Because `configureGRPCClientPipeline` runs
/// as a single synchronous event loop task, the deferred removal is guaranteed to run after that
/// entire task completes — i.e., after `ClientConnectionHandler` is also in the pipeline.
/// Buffered bytes are replayed atomically as part of the pipeline removal.

// FIXME: This handler is needed until the swift GRPC libraries offers us a way to create a
// client transport from an existing fd. Remove this type when such an API exists.
public final class HTTP2ConnectBufferingHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private var removalScheduled = false
    private var bufferedReads: [NIOAny] = []

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bufferedReads.append(data)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        // Suppress while buffering; a single readComplete is emitted after replay.
    }

    public func flush(context: ChannelHandlerContext) {
        if !removalScheduled {
            removalScheduled = true
            // Defer removal to the next event loop task. configureGRPCClientPipeline runs as a
            // single synchronous event loop task, so this deferred task is guaranteed to run
            // after that whole task completes (including ClientConnectionHandler being added).
            context.eventLoop.assumeIsolatedUnsafeUnchecked().execute {
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
            }
        }
        context.flush()
    }

    public func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false
        while !bufferedReads.isEmpty {
            context.fireChannelRead(bufferedReads.removeFirst())
            didRead = true
        }
        if didRead {
            context.fireChannelReadComplete()
        }
        context.leavePipeline(removalToken: removalToken)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        bufferedReads.removeAll()
        context.fireChannelInactive()
    }
}
