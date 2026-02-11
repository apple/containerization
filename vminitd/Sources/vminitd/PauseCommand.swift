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

import Dispatch
import Logging
import Musl

struct PauseCommand {
    static func run(log: Logger) throws {
        if getpid() != 1 {
            log.warning("pause should be the first process")
        }

        // NOTE: For whatever reason, using signal() for the below causes a swift compiler issue.
        // Can revert whenever that is understood.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT)
        sigintSource.setEventHandler {
            log.info("Shutting down, got SIGINT")
            Musl.exit(0)
        }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM)
        sigtermSource.setEventHandler {
            log.info("Shutting down, got SIGTERM")
            Musl.exit(0)
        }
        sigtermSource.resume()

        let sigchldSource = DispatchSource.makeSignalSource(signal: SIGCHLD)
        sigchldSource.setEventHandler {
            var status: Int32 = 0
            while waitpid(-1, &status, WNOHANG) > 0 {}
        }
        sigchldSource.resume()

        log.info("pause container running, waiting for signals...")

        while true {
            Musl.pause()
        }

        log.error("Error: infinite loop terminated")
        Musl.exit(42)
    }
}
