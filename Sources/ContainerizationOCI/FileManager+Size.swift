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

import Foundation

extension FileManager {
    func fileSize(atPath path: String) -> Int64? {
        do {
            let attributes = try attributesOfItem(atPath: path)
            guard let fileSize = attributes[.size] as? NSNumber else {
                return nil
            }
            return fileSize.int64Value
        } catch {
            return nil
        }
    }
}
