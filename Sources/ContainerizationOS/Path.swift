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

/// `Path` provides utilities to look for binaries in the current PATH,
/// or to return the current PATH.
public struct Path {
    /// lookPath looks up an executable's path from $PATH
    public static func lookPath(_ name: String) -> URL? {
        lookup(name, path: getCurrentPath())
    }

    public static func lookPath(_ name: String, path: String) -> URL? {
        lookup(name, path: path)
    }

    // getEnv returns the default environment of the process
    // with the default $PATH added for the context of a macOS application bundle
    public static func getEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = getCurrentPath()
        return env
    }

    private static func lookup(_ name: String, path: String) -> URL? {
        // Return nil for empty names
        if name.isEmpty {
            return nil
        }

        if name.contains("/") {
            if findExec(name) {
                return URL(fileURLWithPath: name)
            }
            return nil
        }

        for var lookdir in path.split(separator: ":") {
            if lookdir.isEmpty {
                lookdir = "."
            }
            let file = URL(fileURLWithPath: String(lookdir)).appendingPathComponent(name)
            if findExec(file.path) {
                return file
            }
        }
        return nil
    }

    /// getPath returns $PATH for the current process
    public static func getCurrentPath() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    // findPath returns a string containing the 'PATH' environment variable
    public static func findPath(_ env: [String]?) -> String? {
        guard let env = env else {
            return nil
        }
        return env.first(where: { $0.hasPrefix("PATH=") })
            .map { String($0.dropFirst(5)) }
    }

    // findExec returns true if the provided path is an executable
    private static func findExec(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: path)
    }
}
