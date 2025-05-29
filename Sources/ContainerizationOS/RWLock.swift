//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the containerization project authors. All rights reserved.
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

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#else
#error("RWLock unsupported on this platform.")
#endif

public final class RWLock: @unchecked Sendable {
    private var rwlock = pthread_rwlock_t()

    public init() {
        withUnsafeMutablePointer(to: &self.rwlock) { ptr in
            guard pthread_rwlock_init(ptr, nil) == 0 else {
                preconditionFailure("pthread rwlock failed to initialize")
            }
        }
    }

    deinit {
        withUnsafeMutablePointer(to: &self.rwlock) { ptr in
            guard pthread_rwlock_destroy(ptr) == 0 else {
                preconditionFailure("pthread rwlock failed to destroy")
            }
        }
    }

    public func lock<T>(_ fn: () throws -> T) rethrows -> T {
        self.lock()
        defer { self.unlock() }

        return try fn()
    }

    public func rlock<T>(_ fn: () throws -> T) rethrows -> T {
        self.rlock()
        defer { self.unlock() }

        return try fn()
    }

    public func lock() {
        withUnsafeMutablePointer(to: &self.rwlock) { ptr in
            guard pthread_rwlock_wrlock(ptr) == 0 else {
                preconditionFailure("pthread rwlock wrlock failed")
            }
        }
    }

    public func rlock() {
        withUnsafeMutablePointer(to: &self.rwlock) { ptr in
            guard pthread_rwlock_rdlock(ptr) == 0 else {
                preconditionFailure("pthread rwlock rdlock failed")
            }
        }
    }

    public func unlock() {
        withUnsafeMutablePointer(to: &self.rwlock) { ptr in
            guard pthread_rwlock_unlock(ptr) == 0 else {
                preconditionFailure("pthread rwlock unlock failed")
            }
        }
    }
}
