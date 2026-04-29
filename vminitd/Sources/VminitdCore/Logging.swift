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

import ArgumentParser
import Foundation
import Logging
import Synchronization

public struct LogLevelOption: ParsableArguments {
    @Option(name: .long, help: "Set the log level (trace, debug, info, notice, warning, error, critical)")
    public var logLevel: String = "info"

    public init() {}

    public func resolvedLogLevel() -> Logger.Level {
        switch logLevel.lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "info":
            return .info
        case "notice":
            return .notice
        case "warning":
            return .warning
        case "error":
            return .error
        case "critical":
            return .critical
        default:
            return .info
        }
    }
}

private let _loggingBootstrapped = Mutex(false)

public func makeLogger(label: String, level: Logger.Level) -> Logger {
    _loggingBootstrapped.withLock { bootstrapped in
        if !bootstrapped {
            LoggingSystem.bootstrap { label in StderrLogHandler(label: label) }
            bootstrapped = true
        }
    }
    var log = Logger(label: label)
    log.logLevel = level
    return log
}

private struct StderrLogHandler: LogHandler {
    let label: String
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        var merged = self.metadata
        metadata?.forEach { merged[$0] = $1 }
        let metaStr = merged.isEmpty ? "" : " \(merged.map { "\($0): \($1)" }.sorted().joined(separator: ", "))"
        let ts = isoTimestamp()
        let data = "\(ts) \(level) \(label):\(metaStr) \(message)\n".data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
    }

    func isoTimestamp() -> String {
        let date = Date()
        var time = time_t(date.timeIntervalSince1970)
        var ms = Int(date.timeIntervalSince1970 * 1000) % 1000
        if ms < 0 { ms += 1000 }
        var tm = tm()
        gmtime_r(&time, &tm)
        let buf = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 32) { ptr -> String in
            strftime(ptr.baseAddress!, 32, "%Y-%m-%dT%H:%M:%S", &tm)
            return String(cString: ptr.baseAddress!)
        }
        return String(format: "%@.%03dZ", buf, ms)
    }
}
