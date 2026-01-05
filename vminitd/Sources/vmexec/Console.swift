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
import Musl

class Console {
    let master: Int32
    let slavePath: String

    init() throws {
        let masterFD = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard masterFD != -1 else {
            throw App.Errno(stage: "open_ptmx")
        }

        guard unlockpt(masterFD) == 0 else {
            throw App.Errno(stage: "unlockpt")
        }

        guard let slavePath = ptsname(masterFD) else {
            throw App.Errno(stage: "ptsname")
        }

        self.master = masterFD
        self.slavePath = String(cString: slavePath)
    }

    func configureStdIO() throws {
        let path = self.slavePath
        let slaveFD = open(path, O_RDWR)
        guard slaveFD != -1 else {
            throw App.Errno(stage: "open_pts")
        }
        defer { Musl.close(slaveFD) }

        for fd: Int32 in 0...2 {
            guard dup3(slaveFD, fd, 0) != -1 else {
                throw App.Errno(stage: "dup3")
            }
        }
    }

    func close() throws {
        guard Musl.close(self.master) == 0 else {
            throw App.Errno(stage: "close")
        }
    }
}
