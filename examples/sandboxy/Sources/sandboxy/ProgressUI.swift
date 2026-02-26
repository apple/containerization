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

import Foundation

/// Status output helpers that write to stderr to keep stdout clean for the agent's terminal IO.
enum ProgressUI {
    private static let boxLines = [
        "┌──────────────┐",
        "│ ░░░░░░░░░░░░ │",
        "│ ░░░░░░░░░░░░ │",
        "│ ░░░░░░░░░░░░ │",
        "│ ░░░░░░░░░░░░ │",
        "│ ░░░░░░░░░░░░ │",
        "│ ░░░░░░░░░░░░ │",
        "└──────────────┘",
    ]

    /// Prints the logo with info lines displayed to the right of the box.
    static func printLogo(info: [String] = []) {
        let yellow = "\u{1b}[33m"
        let reset = "\u{1b}[0m"
        let gap = "  "

        for (i, boxLine) in boxLines.enumerated() {
            let coloredBox = "\(yellow)\(boxLine)\(reset)"
            if i < info.count {
                FileHandle.standardError.write(Data("  \(coloredBox)\(gap)\(info[i])\n".utf8))
            } else {
                FileHandle.standardError.write(Data("  \(coloredBox)\n".utf8))
            }
        }
        // Print any remaining info lines that don't fit beside the box.
        if info.count > boxLines.count {
            for j in boxLines.count..<info.count {
                let indent = String(repeating: " ", count: 2 + boxLines[0].count + gap.count)
                FileHandle.standardError.write(Data("\(indent)\(info[j])\n".utf8))
            }
        }
    }

    static func printStatus(_ message: String) {
        FileHandle.standardError.write(Data("\u{1b}[32m==> \(message)\u{1b}[0m\n".utf8))
    }

    static func printDetail(_ message: String) {
        FileHandle.standardError.write(Data("\u{1b}[32m  \(message)\u{1b}[0m\n".utf8))
    }

    static func printWarning(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\u{1b}[31merror: \(message)\u{1b}[0m\n".utf8))
    }
}
