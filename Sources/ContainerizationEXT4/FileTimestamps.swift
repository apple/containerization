//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors. All rights reserved.
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

public struct FileTimestamps {
    private let access: Date
    private let modification: Date
    private let creation: Date
    private let now: Date

    var accessLo: UInt32 {
        access.fs().lo
    }

    var accessHi: UInt32 {
        access.fs().hi
    }

    var modificationLo: UInt32 {
        modification.fs().lo
    }

    var modificationHi: UInt32 {
        modification.fs().hi
    }

    var creationLo: UInt32 {
        creation.fs().lo
    }

    var creationHi: UInt32 {
        creation.fs().hi
    }

    var nowLo: UInt32 {
        now.fs().lo
    }

    var nowHi: UInt32 {
        now.fs().hi
    }

    init(access: Date?, modification: Date?, creation: Date?) {
        now = Date()
        self.access = access ?? now
        self.modification = modification ?? now
        self.creation = creation ?? now
    }

    public init() {
        self.init(access: nil, modification: nil, creation: nil)
    }
}
