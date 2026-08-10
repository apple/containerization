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
#endif

/// Ignore SIGPIPE for the test process.
///
/// Several suites in this target drive sockets/pipes with raw `write(2)` /
/// `sendmsg(2)` whose peer may already be closed (e.g. the BidirectionalRelay,
/// SCM_RIGHTS, and epoll pipe tests). On Linux a write to a closed peer raises
/// SIGPIPE, whose default disposition terminates the entire `swift test`
/// process (signal 13); swift-testing runs suites concurrently, so this shows
/// up as an intermittent whole-run crash. macOS masks it per-socket, so this is
/// Linux-specific.
///
/// swift-testing has no global setUp hook, so suites that touch sockets/pipes
/// call this from `init()`. `signal` sets a process-wide disposition and the
/// call is idempotent, so invoking it before each such suite's test bodies run
/// is enough to keep any of their writes from killing the run.
func ignoreSIGPIPEForTests() {
    _ = signal(SIGPIPE, SIG_IGN)
}
