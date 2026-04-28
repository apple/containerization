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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Signal not supported on this platform.")
#endif

/// A unix signal.
public struct Signal: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Parse a signal from a string representation (e.g. "SIGKILL", "KILL", "9").
    public init(_ name: String, from map: [String: Int32] = Signal.linux) throws {
        var signalUpper = name.uppercased()
        signalUpper.trimPrefix("SIG")
        if let sig = Int32(signalUpper) {
            if !map.values.contains(sig) {
                throw SignalError.invalidSignal(name)
            }
            self.rawValue = sig
            return
        }
        guard let sig = map[signalUpper] else {
            throw SignalError.invalidSignal(name)
        }
        self.rawValue = sig
    }

    // Signals that are commonly sent to containers and share the same
    // number across macOS/Linux.
    public static let hup = Signal(rawValue: 1)
    public static let int = Signal(rawValue: 2)
    public static let quit = Signal(rawValue: 3)
    public static let kill = Signal(rawValue: 9)
    public static let term = Signal(rawValue: 15)
    public static let winch = Signal(rawValue: 28)

    /// Linux signals.
    public enum Linux {
        public static let hup = Signal(rawValue: 1)
        public static let int = Signal(rawValue: 2)
        public static let quit = Signal(rawValue: 3)
        public static let ill = Signal(rawValue: 4)
        public static let trap = Signal(rawValue: 5)
        public static let abrt = Signal(rawValue: 6)
        public static let bus = Signal(rawValue: 7)
        public static let fpe = Signal(rawValue: 8)
        public static let kill = Signal(rawValue: 9)
        public static let usr1 = Signal(rawValue: 10)
        public static let segv = Signal(rawValue: 11)
        public static let usr2 = Signal(rawValue: 12)
        public static let pipe = Signal(rawValue: 13)
        public static let alrm = Signal(rawValue: 14)
        public static let term = Signal(rawValue: 15)
        public static let stkflt = Signal(rawValue: 16)
        public static let chld = Signal(rawValue: 17)
        public static let cont = Signal(rawValue: 18)
        public static let stop = Signal(rawValue: 19)
        public static let tstp = Signal(rawValue: 20)
        public static let ttin = Signal(rawValue: 21)
        public static let ttou = Signal(rawValue: 22)
        public static let urg = Signal(rawValue: 23)
        public static let xcpu = Signal(rawValue: 24)
        public static let xfsz = Signal(rawValue: 25)
        public static let vtalrm = Signal(rawValue: 26)
        public static let prof = Signal(rawValue: 27)
        public static let winch = Signal(rawValue: 28)
        public static let io = Signal(rawValue: 29)
        public static let poll = Signal(rawValue: 29)
        public static let pwr = Signal(rawValue: 30)
        public static let sys = Signal(rawValue: 31)

        public static func rtmin(offset: Int32 = 0) -> Signal {
            Signal(rawValue: 34 + offset)
        }

        public static let rtmax = Signal(rawValue: 64)
    }

    /// Darwin signals.
    public enum Darwin {
        public static let hup = Signal(rawValue: 1)
        public static let int = Signal(rawValue: 2)
        public static let quit = Signal(rawValue: 3)
        public static let ill = Signal(rawValue: 4)
        public static let trap = Signal(rawValue: 5)
        public static let abrt = Signal(rawValue: 6)
        public static let emt = Signal(rawValue: 7)
        public static let fpe = Signal(rawValue: 8)
        public static let kill = Signal(rawValue: 9)
        public static let bus = Signal(rawValue: 10)
        public static let segv = Signal(rawValue: 11)
        public static let sys = Signal(rawValue: 12)
        public static let pipe = Signal(rawValue: 13)
        public static let alrm = Signal(rawValue: 14)
        public static let term = Signal(rawValue: 15)
        public static let urg = Signal(rawValue: 16)
        public static let stop = Signal(rawValue: 17)
        public static let tstp = Signal(rawValue: 18)
        public static let cont = Signal(rawValue: 19)
        public static let chld = Signal(rawValue: 20)
        public static let ttin = Signal(rawValue: 21)
        public static let ttou = Signal(rawValue: 22)
        public static let io = Signal(rawValue: 23)
        public static let xcpu = Signal(rawValue: 24)
        public static let xfsz = Signal(rawValue: 25)
        public static let vtalrm = Signal(rawValue: 26)
        public static let prof = Signal(rawValue: 27)
        public static let winch = Signal(rawValue: 28)
        public static let info = Signal(rawValue: 29)
        public static let usr1 = Signal(rawValue: 30)
        public static let usr2 = Signal(rawValue: 31)
    }

    /// All Linux signals including real-time signals (RTMIN through RTMAX).
    public static let linux: [String: Int32] = [
        "ABRT": 6,
        "ALRM": 14,
        "BUS": 7,
        "CHLD": 17,
        "CLD": 17,
        "CONT": 18,
        "FPE": 8,
        "HUP": 1,
        "ILL": 4,
        "INT": 2,
        "IO": 29,
        "IOT": 6,
        "KILL": 9,
        "PIPE": 13,
        "POLL": 29,
        "PROF": 27,
        "PWR": 30,
        "QUIT": 3,
        "SEGV": 11,
        "STKFLT": 16,
        "STOP": 19,
        "SYS": 31,
        "TERM": 15,
        "TRAP": 5,
        "TSTP": 20,
        "TTIN": 21,
        "TTOU": 22,
        "URG": 23,
        "USR1": 10,
        "USR2": 12,
        "VTALRM": 26,
        "WINCH": 28,
        "XCPU": 24,
        "XFSZ": 25,
        "RTMIN": 34,
        "RTMIN+1": 35,
        "RTMIN+2": 36,
        "RTMIN+3": 37,
        "RTMIN+4": 38,
        "RTMIN+5": 39,
        "RTMIN+6": 40,
        "RTMIN+7": 41,
        "RTMIN+8": 42,
        "RTMIN+9": 43,
        "RTMIN+10": 44,
        "RTMIN+11": 45,
        "RTMIN+12": 46,
        "RTMIN+13": 47,
        "RTMIN+14": 48,
        "RTMIN+15": 49,
        "RTMIN+16": 50,
        "RTMIN+17": 51,
        "RTMIN+18": 52,
        "RTMIN+19": 53,
        "RTMIN+20": 54,
        "RTMIN+21": 55,
        "RTMIN+22": 56,
        "RTMIN+23": 57,
        "RTMIN+24": 58,
        "RTMIN+25": 59,
        "RTMIN+26": 60,
        "RTMIN+27": 61,
        "RTMIN+28": 62,
        "RTMIN+29": 63,
        "RTMAX": 64,
    ]
}

#if os(macOS)

extension Signal {
    /// All signals for the macOS host.
    public static let platform: [String: Int32] = [
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

#elseif os(Linux)

extension Signal {
    /// All signals for the Linux host.
    public static let platform = linux
}

#endif

extension Signal: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int32) {
        self.rawValue = value
    }
}

/// Errors that can be encountered for converting signals.
public enum SignalError: Error, CustomStringConvertible {
    case invalidSignal(String)

    public var description: String {
        switch self {
        case .invalidSignal(let sig):
            return "invalid signal: \(sig)"
        }
    }
}
