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
import SystemPackage

public final class FileArchiveWriterDelegate: ArchiveWriterDelegate {

    public let path: FilePath
    private var fd: FileDescriptor!

    public init(path: FilePath) {
        self.path = path
    }

    public convenience init(url: URL) {
        self.init(path: FilePath(url.path))
    }

    public func open(archive: ArchiveWriter) throws {
        self.fd = try FileDescriptor.open(
            self.path, .writeOnly, options: [.create, .append], permissions: [.groupRead, .otherRead, .ownerReadWrite])
    }

    public func write(archive: ArchiveWriter, buffer: UnsafeRawBufferPointer) throws -> Int {
        try fd.write(buffer)
    }

    public func close(archive: ArchiveWriter) throws {
        try self.fd.close()
    }

    public func free(archive: ArchiveWriter) {
        self.fd = nil
    }

    deinit {
        if let fd = self.fd {
            try? fd.close()
        }
    }
}

extension ArchiveWriter {
    public convenience init(configuration: ArchiveWriterConfiguration, file: URL) throws {
        try self.init(configuration: configuration, delegate: FileArchiveWriterDelegate(url: file))
    }
    public convenience init(format: Format, filter: Filter, options: [Options] = [], file: URL) throws {
        try self.init(
            configuration: .init(format: format, filter: filter), delegate: FileArchiveWriterDelegate(url: file))
    }
}
