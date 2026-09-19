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

#if os(Linux)

import Cgroup

/// Narrow cross-package access to cgroup descriptors used by vmexec's
/// clone3(CLONE_INTO_CGROUP) process-admission path.
public enum CgroupProcessAdmission {
    public static func openForCloning(_ manager: Cgroup2Manager) throws -> Int32 {
        try manager.openForCloning()
    }

    public static func openForCloning(parentPid: Int32) throws -> Int32 {
        let manager = try Cgroup2Manager.loadFromPid(pid: parentPid)
        return try manager.openForCloning()
    }
}

#endif
