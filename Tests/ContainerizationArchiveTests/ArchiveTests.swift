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

//

import Foundation
import Testing

@testable import ContainerizationArchive

struct ArchiveTests {
    func helperEntry(path: String, data: Data) -> WriteEntry {
        let entry = WriteEntry()
        entry.permissions = 0o644
        entry.fileType = .regular
        entry.path = path
        entry.size = numericCast(data.count)
        entry.owner = 1
        entry.group = 2
        entry.xattrs = ["user.data": Data([1, 2, 3])]
        return entry
    }

    @Test func tarUTF8() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testTarUTF8")!
        let archiveURL = testDirectory.appendingPathComponent("test.tgz")

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        // this test would failed with ArchiveWriterConfiguration.locale was not set to "en_US.UTF-8"
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .gzip, file: archiveURL)

        let data = "blablabla".data(using: .utf8)!

        let normalPathEntry = helperEntry(path: "r", data: data)
        #expect(throws: Never.self) {
            try archiver.writeEntry(entry: normalPathEntry, data: data)
        }

        let weirdPathEntry = helperEntry(path: "ʀ", data: data)
        #expect(throws: Never.self) {
            try archiver.writeEntry(entry: weirdPathEntry, data: data)
        }
    }

    @Test func tarGzipWithOpenfile() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testTarGzipWithOpenfile")!
        let archiveURL = testDirectory.appendingPathComponent("test.tgz")

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        let configuration = ArchiveWriterConfiguration(
            format: .paxRestricted,
            filter: .gzip
        )
        let archiver = try ArchiveWriter(configuration: configuration)
        try archiver.open(file: archiveURL)

        let data = "foo".data(using: .utf8)!

        let normalPathEntry = helperEntry(path: "bar", data: data)
        #expect(throws: Never.self) {
            try archiver.writeEntry(entry: normalPathEntry, data: data)
        }

        try archiver.finishEncoding()
    }

    @Test func writingZip() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testWritingZip")!
        let archiveURL = testDirectory.appendingPathComponent("test.zip")

        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        // When
        let archiver = try ArchiveWriter(format: .zip, filter: .none, file: archiveURL)

        var data = "foo".data(using: .utf8)!
        var entry = helperEntry(path: "foo.txt", data: data)
        try archiver.writeEntry(entry: entry, data: data)

        data = "bar".data(using: .utf8)!
        entry = helperEntry(path: "bar.txt", data: data)
        try archiver.writeEntry(entry: entry, data: data)

        data = Data()
        entry = helperEntry(path: "empty", data: data)
        try archiver.writeEntry(entry: entry, data: data)

        try archiver.finishEncoding()

        // Then
        let unarchiver = try ArchiveReader(format: .zip, filter: .none, file: archiveURL)
        for (index, (entry, data)) in unarchiver.enumerated() {
            #expect(entry.owner == 1)
            #expect(entry.group == 2)
            switch index {
            case 0:
                #expect(entry.path == "foo.txt")
                #expect(String(data: data, encoding: .utf8) == "foo")
            case 1:
                #expect(entry.path == "bar.txt")
                #expect(String(data: data, encoding: .utf8) == "bar")
            case 2:
                #expect(entry.path == "empty")
                #expect(data.isEmpty)
            default:
                Issue.record()
            }
        }
    }

    @Test func unarchiving_0bytesEntry() throws {
        let data = Data(base64Encoded: surveyBundleBase64Encoded)!
        let unarchiver = try ArchiveReader(name: "survey.zip", bundle: data)
        for (index, (entry, data)) in unarchiver.enumerated() {
            switch index {
            case 0:
                #expect(entry.path == "healthinvolvement.js")
                #expect(!data.isEmpty)
            case 1:
                #expect(entry.path == "__MACOSX/")
                #expect(data.isEmpty)
            case 2:
                #expect(entry.path == "__MACOSX/._healthinvolvement.js")
                #expect(!data.isEmpty)
            default:
                Issue.record()
            }
        }
    }

    @Test func writingReadingTar() throws {
        let testDirectory = createTemporaryDirectory(baseName: "ArchiveTests.testWritingReadingTar")!
        let archiveURL = testDirectory.appendingPathComponent("test.tar.gz")
        defer {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: testDirectory)
        }

        let archiver = try ArchiveWriter(format: .pax, filter: .gzip, file: archiveURL)
        let data = "foo".data(using: .utf8)!
        let entry = helperEntry(path: "foo.txt", data: data)
        try archiver.writeEntry(entry: entry, data: data)
        try archiver.finishEncoding()

        let unarchiver = try ArchiveReader(format: .pax, filter: .gzip, file: archiveURL)
        for (entry, _) in unarchiver {
            let attrs = entry.xattrs
            guard let val = attrs["user.data"] else {
                Issue.record("missing extended attribute [user.data] in file")
                return
            }
            #expect([UInt8](val) == [1, 2, 3])
        }
    }
}

private let surveyBundleBase64Encoded = """
    UEsDBBQACAAIAA17o04AAAAAAAAAAAAAAAAUABAAaGVhbHRoaW52b2x2ZW1lbnQuanNVWAwAQ8XMXJm/zFz1ARQAnVVRa9swEH73rzjylMLwmu3NJexhDLqxroPAYIxRFPsca5UlT5LteSH/fSdZdu02LqMiEEl3uvv06e5zwzRwyS1n4q4qmEHYwjECGn6VwKrSXGluu9Urv50rXSbBxWBquZImgR9+/Wgcz226IVTKBP+L2We2R0E5rlULrapFBp2qYY/GQoYm1XyPbsdBbJRosERpaQ7cmBoNaBTMYgZW9V4FMmGLdwBfBbqrpIVS9KckxgH9mXGPHSGYJFh2ZdK0qJPli9mucpTtuDwIfF8onuJytNTbl8ibj+NTzr4oC4x+QgzsZDHcdIGElGmESquGZ6gh45qeykDpyAgeI3s9mcQQNEzUhP8STougn4W0UyW2BbMTQB8h9e9KD5kpogVKRcDowUom2QGhHABP8m9emv8b6m6W29KacrVK3wMzwMAiK6HldPvyPFPPI3vzUmQf/lhNxSXm8FQrH9JQdWVA6JgEljUUwKJrNnIwKPIJiLf/BeLnksvyYW5uK9fPjBDnTBg853h6vNknOkWnKMpr6QUB0EGlC6yxoYa6CA3TkNYMGuMNsV9dRd7Kc1gH63brGtKL0upi0m0aba3lXK9C9mhiP47alVHrrxaw3Wk0FYkXmvU4G5KFQOP+LADVyoEsZn65cOR2/4s6LSZRCfb4IXgsUB7ooV/DxgV0dPymznNBJaMOHaWXKlFannOnNatUlTFLWxRCUtJ4diLuS+epeFluhSPgxtWya7vvTh+vvXdw6QXWP7hTYG/q4BP5SexgV+sGB81vUJvebRNfDt+BQEcyEtrvh5XSyRmme5eBwGScOTqi2c2uon9QSwcIxOijbWkCAACaBgAAUEsDBAoAAAAAAFV+o04AAAAAAAAAAAAAAAAJABAAX19NQUNPU1gvVVgMAMHFzFzBxcxc9QEUAFBLAwQUAAgACAANe6NOAAAAAAAAAAAAAAAAHwAQAF9fTUFDT1NYLy5faGVhbHRoaW52b2x2ZW1lbnQuanNVWAwAQ8XMXJm/zFz1ARQAjY/NSsNAEMcnRfHjVBA9eLGiHjy0m5qkDa2XtGlrwVKxAUUUWZMpiW4+mmzrxZtP4pOINw8efQXx6BMIbmigUBAd2P/MDr8/MwOLG0uQA+hRu9AfFM4LWaQ9WBHvAED6Eln8c9vwrzAs63RapQ5pVxTfc8hC1s8DbNqhX6JRxLDEaMLHCToO5bhzMpiikipEA9ifcT5yKhhau+uZXY6+Gd4HLKQOOqZwph5PyAPA3u+eMxdjbMehn6T8h5BDgPUZPxrTmAbcCxDen98u002cz9dymm8i5iVclp8kxXghV7j1eLO8mi0rZQfm5g5em5mu8z2X8yipERJhFGFsu5RnU8V8MvQYJqRMNLVK/LDV71iMWW583OyY5Agp4243mIRsgj4GvHSb/Dn7YkRkWVfqmk1RV3RaH9Ahjb16y6hUKxVNK8rtcqOo6kIastooNlXT1IyWoTYVA34AUEsHCAK+cV1ZAQAAIQIAAFBLAQIVAxQACAAIAA17o07E6KNtaQIAAJoGAAAUAAwAAAAAAAAAAECkgQAAAABoZWFsdGhpbnZvbHZlbWVudC5qc1VYCABDxcxcmb/MXFBLAQIVAwoAAAAAAFV+o04AAAAAAAAAAAAAAAAJAAwAAAAAAAAAAED9QbsCAABfX01BQ09TWC9VWAgAwcXMXMHFzFxQSwECFQMUAAgACAANe6NOAr5xXVkBAAAhAgAAHwAMAAAAAAAAAABApIHyAgAAX19NQUNPU1gvLl9oZWFsdGhpbnZvbHZlbWVudC5qc1VYCABDxcxcmb/MXFBLBQYAAAAAAwADAOoAAACoBAAAAAA=
    """
