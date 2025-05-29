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

import CArchive

public protocol ArchiveWriterDelegate: AnyObject {
    /// The open callback is invoked by archive_write_open().  It should return ARCHIVE_OK if the underlying file or data source is successfully opened.  If the open fails, it should call archive_set_error() to register an error code and message and return ARCHIVE_FATAL.  Please note that
    /// if open fails, close is not called and resources must be freed inside the open callback or with the free callback.
    func open(archive: ArchiveWriter) throws
    /// returns number of bytes written
    func write(archive: ArchiveWriter, buffer: UnsafeRawBufferPointer) throws -> Int
    /// The close callback is invoked by archive_close when the archive processing is complete. If the open callback fails, the close callback is not invoked.  The callback should return ARCHIVE_OK on success.  On failure, the callback should invoke archive_set_error() to register an
    /// error code and message and return
    func close(archive: ArchiveWriter) throws
    /// The free callback is always invoked on archive_free.  The return code of this callback is not processed.
    func free(archive: ArchiveWriter)
}
