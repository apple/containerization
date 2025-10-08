//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
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

/// Helper type to deal with system control functionalities.
public struct Sysctl {
    #if os(macOS)
    /// Simple `sysctlbyname` wrapper.
    public static func byName(_ name: String) throws -> Int64 {
        var num: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &num, &size, nil, 0) != 0 {
            throw POSIXError.fromErrno()
        }
        return num
    }
    #endif
}
