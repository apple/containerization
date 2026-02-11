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

#if os(Linux)

import Cgroup
import Foundation
import Logging

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

package final class MemoryMonitor: Sendable {
    private static let inotifyEventSize = 0x10

    private let cgroupManager: Cgroup2Manager
    private let threshold: UInt64
    private let logger: Logger
    private let inotifyFd: Int32
    private let watchDescriptor: Int32
    private let onThresholdExceeded: @Sendable (UInt64, UInt64) -> Void

    package init(
        cgroupManager: Cgroup2Manager,
        threshold: UInt64,
        logger: Logger,
        onThresholdExceeded: @escaping @Sendable (UInt64, UInt64) -> Void
    ) throws {
        self.cgroupManager = cgroupManager
        self.threshold = threshold
        self.logger = logger
        self.onThresholdExceeded = onThresholdExceeded

        let fd = inotify_init()
        guard fd != -1 else {
            throw Error.inotifyInit(errno: errno)
        }
        self.inotifyFd = fd

        let eventsPath = cgroupManager.getMemoryEventsPath()
        let wd = inotify_add_watch(
            inotifyFd,
            eventsPath,
            UInt32(IN_MODIFY)
        )
        guard wd != -1 else {
            close(fd)
            throw Error.inotifyAddWatch(errno: errno, path: eventsPath)
        }
        self.watchDescriptor = wd
    }

    /// Run the monitoring loop. Call this from a dedicated thread.
    /// This function blocks until an error occurs.
    package func run() throws {
        let eventsPath = cgroupManager.getMemoryEventsPath()

        logger.info(
            "Started memory monitoring",
            metadata: [
                "threshold_bytes": "\(threshold)",
                "events_path": "\(eventsPath)",
            ])

        // Read initial state
        var highCountMax: UInt64 = 0
        do {
            let events = try cgroupManager.getMemoryEvents()
            highCountMax = events.high
        } catch {
            throw Error.readMemoryEvents(error: error)
        }

        let bufSize = Self.inotifyEventSize * 10
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                read(inotifyFd, ptr.baseAddress!, bufSize)
            }

            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw Error.readFailed(errno: errno)
            }

            do {
                let events = try cgroupManager.getMemoryEvents()

                if events.high > highCountMax {
                    highCountMax = events.high

                    let stats = try cgroupManager.stats()
                    let currentUsage = stats.memory?.usage ?? 0

                    onThresholdExceeded(currentUsage, events.high)
                }

                if events.oom > 0 || events.oomKill > 0 {
                    logger.error(
                        "OOM events detected",
                        metadata: [
                            "oom_events": "\(events.oom)",
                            "oom_kill_events": "\(events.oomKill)",
                        ])
                }
            } catch {
                throw Error.readMemoryEvents(error: error)
            }
        }
    }

    deinit {
        inotify_rm_watch(inotifyFd, watchDescriptor)
        close(inotifyFd)
    }
}

extension MemoryMonitor {
    package enum Error: Swift.Error, CustomStringConvertible {
        case inotifyInit(errno: Int32)
        case inotifyAddWatch(errno: Int32, path: String)
        case readFailed(errno: Int32)
        case readMemoryEvents(error: Swift.Error)

        package var description: String {
            switch self {
            case .inotifyInit(let errno):
                return "failed to initialize inotify: errno \(errno)"
            case .inotifyAddWatch(let errno, let path):
                return "failed to add inotify watch on \(path): errno \(errno)"
            case .readFailed(let errno):
                return "failed to read inotify events: errno \(errno)"
            case .readMemoryEvents(let error):
                return "failed to read memory events: \(error)"
            }
        }
    }
}

#endif
