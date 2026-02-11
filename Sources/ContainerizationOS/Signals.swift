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

/// Helper type with utilities to parse and manipulate unix signals.
public struct Signals {
    /// Returns the numeric values of all known signals.
    public static func allNumeric() -> [Int32] {
        Array(Signals.all.values)
    }

    /// Parses a string representation of a signal (SIGKILL) and returns
    // the 32 bit integer representation (9).
    public static func parseSignal(_ signal: String) throws -> Int32 {
        if let sig = Int32(signal) {
            if !Signals.all.values.contains(sig) {
                throw Error.invalidSignal(signal)
            }
            return sig
        }
        var signalUpper = signal.uppercased()
        signalUpper.trimPrefix("SIG")
        guard let sig = Signals.all[signalUpper] else {
            throw Error.invalidSignal(signal)
        }
        return sig
    }

    /// Errors that can be encountered for converting signals.
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidSignal(String)

        public var description: String {
            switch self {
            case .invalidSignal(let sig):
                return "invalid signal: \(sig)"
            }
        }
    }
}

#if os(macOS)

extension Signals {
    /// `all` returns all signals for the current platform.
    public static let all: [String: Int32] = [
        "ABRT": SIGABRT,
        "ALRM": SIGALRM,
        "BUS": SIGBUS,
        "CHLD": SIGCHLD,
        "CONT": SIGCONT,
        "EMT": SIGEMT,
        "FPE": SIGFPE,
        "HUP": SIGHUP,
        "ILL": SIGILL,
        "INFO": SIGINFO,
        "INT": SIGINT,
        "IO": SIGIO,
        "IOT": SIGIOT,
        "KILL": SIGKILL,
        "PIPE": SIGPIPE,
        "PROF": SIGPROF,
        "QUIT": SIGQUIT,
        "SEGV": SIGSEGV,
        "STOP": SIGSTOP,
        "SYS": SIGSYS,
        "TERM": SIGTERM,
        "TRAP": SIGTRAP,
        "TSTP": SIGTSTP,
        "TTIN": SIGTTIN,
        "TTOU": SIGTTOU,
        "URG": SIGURG,
        "USR1": SIGUSR1,
        "USR2": SIGUSR2,
        "VTALRM": SIGVTALRM,
        "WINCH": SIGWINCH,
        "XCPU": SIGXCPU,
        "XFSZ": SIGXFSZ,
    ]
}

#endif

#if os(Linux)

extension Signals {
    /// `all` returns all signals for the current platform.
    ///
    /// For Linux this isn't actually exhaustive as it excludes
    /// rtmin/rtmax entries.
    public static let all: [String: Int32] = [
        "ABRT": SIGABRT,
        "ALRM": SIGALRM,
        "BUS": SIGBUS,
        "CHLD": SIGCHLD,
        "CLD": SIGCHLD,
        "CONT": SIGCONT,
        "FPE": SIGFPE,
        "HUP": SIGHUP,
        "ILL": SIGILL,
        "INT": SIGINT,
        "IO": SIGIO,
        "IOT": SIGIOT,
        "KILL": SIGKILL,
        "PIPE": SIGPIPE,
        "POLL": SIGPOLL,
        "PROF": SIGPROF,
        "PWR": SIGPWR,
        "QUIT": SIGQUIT,
        "SEGV": SIGSEGV,
        "STKFLT": SIGSTKFLT,
        "STOP": SIGSTOP,
        "SYS": SIGSYS,
        "TERM": SIGTERM,
        "TRAP": SIGTRAP,
        "TSTP": SIGTSTP,
        "TTIN": SIGTTIN,
        "TTOU": SIGTTOU,
        "URG": SIGURG,
        "USR1": SIGUSR1,
        "USR2": SIGUSR2,
        "VTALRM": SIGVTALRM,
        "WINCH": SIGWINCH,
        "XCPU": SIGXCPU,
        "XFSZ": SIGXFSZ,
    ]
}

#endif
