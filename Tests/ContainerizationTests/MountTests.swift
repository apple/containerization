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
import Testing

@testable import Containerization

final class MountTests {
    @Test func fileDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("testfile.txt")
        
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }
        
        let mount = Mount.share(
            source: testFile.path,
            destination: "/app/config.txt"
        )
        
        #expect(mount.isFile == true)
        #expect(mount.filename == "testfile.txt")
        #expect(mount.parentDirectory == tempDir.path)
    }
    
    @Test func directoryDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory
        
        let mount = Mount.share(
            source: tempDir.path,
            destination: "/app/data"
        )
        
        #expect(mount.isFile == false)
    }
    
    #if os(macOS)
    @Test func attachedFilesystemBindFlag() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("bindtest.txt")
        
        try "bind test".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }
        
        let mount = Mount.share(
            source: testFile.path,
            destination: "/app/config.txt"
        )
        
        let allocator = Character.allocator(start: "a")
        let attached = try AttachedFilesystem(mount: mount, allocator: allocator)
        
        #expect(attached.isFileBind == true)
        #expect(attached.type == "virtiofs")
    }
    #endif
}