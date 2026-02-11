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
import Logging

actor TimeSyncer {
    private var task: Task<Void, Never>?
    private var context: Vminitd?
    private var paused: Bool
    private let logger: Logger?

    init(logger: Logger?) {
        self.paused = false
        self.logger = logger
    }

    func start(context: Vminitd, interval: Duration = .seconds(30)) {
        guard self.task == nil else {
            return
        }

        self.context = context
        self.task = Task {
            while true {
                do {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }

                    guard !paused else {
                        continue
                    }

                    var timeval = timeval()
                    guard gettimeofday(&timeval, nil) == 0 else {
                        throw POSIXError.fromErrno()
                    }

                    try await context.setTime(
                        sec: Int64(timeval.tv_sec),
                        usec: Int32(timeval.tv_usec)
                    )
                } catch {
                    self.logger?.error("failed to sync time with guest agent: \(error)")
                }
            }
        }
    }

    func pause() async {
        self.paused = true
    }

    func resume() async {
        self.paused = false
    }

    func close() async throws {
        guard let task else {
            // Already closed, nop.
            return
        }

        task.cancel()
        await task.value

        try await self.context?.close()
        self.task = nil
        self.context = nil
    }
}
