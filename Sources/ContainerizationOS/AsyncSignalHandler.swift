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
import Synchronization

/// Async friendly wrapper around `DispatchSourceSignal`. Provides an `AsyncStream`
/// interface to get notified of received signals.
public final class AsyncSignalHandler: Sendable {
    /// An async stream that returns the signal that was caught, if ever.
    public var signals: AsyncStream<Int32> {
        let (stream, cont) = AsyncStream.makeStream(of: Int32.self)
        self.state.withLock {
            $0.conts.append(cont)
        }
        cont.onTermination = { @Sendable _ in
            self.cancel()
        }
        return stream
    }

    /// Cancel every AsyncStream of signals, as well as the underlying
    /// DispatchSignalSource's for each registered signal.
    public func cancel() {
        self.state.withLock {
            if $0.conts.isEmpty {
                return
            }

            for cont in $0.conts {
                cont.finish()
            }
            for source in $0.sources {
                source.cancel()
            }
            $0.conts.removeAll()
            $0.sources.removeAll()
        }
    }

    struct State: Sendable {
        var conts: [AsyncStream<Int32>.Continuation] = []
        // `sources` isn't used concurrently.
        nonisolated(unsafe) var sources: [any DispatchSourceSignal] = []
    }

    // We keep a reference to the continuation object that is created for
    // our AsyncStream and tell our signal handler to yield a value to it
    // returning a value to the consumer
    private func handler(_ sig: Int32) {
        self.state.withLock {
            for cont in $0.conts {
                cont.yield(sig)
            }
        }
    }

    private let state: Mutex<State> = .init(State())

    /// Create a new `AsyncSignalHandler` for the list of given signals `notify`.
    /// The default signal handlers for these signals are removed and async handlers
    /// added in their place. The async signal handlers that are installed simply
    /// yield to a stream if and when a signal is caught.
    public static func create(notify on: [Int32]) -> AsyncSignalHandler {
        let out = AsyncSignalHandler()
        var sources = [any DispatchSourceSignal]()
        for sig in on {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig)
            source.setEventHandler {
                out.handler(sig)
            }
            source.resume()
            // Retain a reference to our signal sources so that they
            // do not go out of scope.
            sources.append(source)
        }
        out.state.withLock { $0.sources = sources }
        return out
    }
}
