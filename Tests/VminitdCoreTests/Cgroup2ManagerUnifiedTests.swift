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

#if os(Linux)

import Cgroup
import ContainerizationOCI
import Foundation
import Testing

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// `applyResources` writes `linux.resources.unified` into the container's cgroup.
/// A directory of plain files stands in for the cgroup: `writeValue` opens each file
/// without O_CREAT, as a cgroup file must already exist.
@Suite("Cgroup2Manager unified resources")
struct Cgroup2ManagerUnifiedTests {
    /// A cgroup directory `<tmp>/c` holding the given files, empty.
    private func makeCgroup(files: [String]) throws -> (Cgroup2Manager, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cg2-unified-\(UUID().uuidString)")
        let dir = root.appending(path: "c")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            #expect(FileManager.default.createFile(atPath: dir.appending(path: f).path, contents: nil))
        }
        return (Cgroup2Manager(mountPoint: root, group: URL(filePath: "/c")), dir)
    }

    private func read(_ dir: URL, _ file: String) throws -> String {
        try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    /// `memory.oom.group=1` next to the memory limit, the common request on cgroup v2.
    @Test func writesMemoryOOMGroup() throws {
        let (cg, dir) = try makeCgroup(files: ["memory.max", "memory.oom.group"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try cg.applyResources(
            resources: LinuxResources(memory: LinuxMemory(limit: 1_073_741_824), unified: ["memory.oom.group": "1"]))
        #expect(try read(dir, "memory.max") == "1073741824")
        #expect(try read(dir, "memory.oom.group") == "1")
    }

    /// A key in `unified` is written after the typed fields, so it wins, as in runc.
    @Test func unifiedWinsOverTypedFields() throws {
        let (cg, dir) = try makeCgroup(files: ["memory.max"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try cg.applyResources(
            resources: LinuxResources(memory: LinuxMemory(limit: 1024), unified: ["memory.max": "2048"]))
        #expect(try read(dir, "memory.max") == "2048")
    }

    /// No `unified` (nil or empty) writes nothing beyond the typed fields.
    @Test func emptyUnifiedWritesNothing() throws {
        let (cg, dir) = try makeCgroup(files: ["memory.max", "memory.oom.group"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        var resources = LinuxResources(memory: LinuxMemory(limit: 1024))
        try cg.applyResources(resources: resources)
        resources.unified = nil
        try cg.applyResources(resources: resources)
        #expect(try read(dir, "memory.oom.group") == "")
    }

    /// A key that is not a file name in the cgroup directory is rejected before any write,
    /// the typed fields included.
    @Test(arguments: ["", ".", "..", "../memory.max", "a/b", "/memory.max"])
    func rejectsPathKeys(key: String) throws {
        let (cg, dir) = try makeCgroup(files: ["memory.max"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(!Cgroup2Manager.isUnifiedFileName(key))
        #expect(throws: Cgroup2Manager.Error.self) {
            try cg.applyResources(
                resources: LinuxResources(memory: LinuxMemory(limit: 1024), unified: [key: "1", "memory.oom.group": "1"]))
        }
        #expect(try read(dir, "memory.max") == "")
    }

    /// A file the cgroup does not have (its controller is not enabled, or the kernel is too
    /// old) fails the apply with ENOENT, as runc fails the container create.
    @Test func missingFileFails() throws {
        let (cg, dir) = try makeCgroup(files: [])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        do {
            try cg.applyResources(resources: LinuxResources(unified: ["memory.oom.group": "1"]))
            Issue.record("applyResources succeeded without memory.oom.group")
        } catch Cgroup2Manager.Error.errno(let code, _) {
            #expect(code == ENOENT)
        }
    }

    /// With an OCI runtime (runc) the guest writes no cgroup file itself: runc applies
    /// `linux.resources.unified` from the bundle's config.json.
    /// The spec goes from the host as JSON, the guest decodes it, and the bundle encodes it
    /// again, so `unified` must survive both steps under its OCI key.
    @Test func runcBundleCarriesUnified() throws {
        var hostSpec = ContainerizationOCI.Spec(linux: Linux(resources: LinuxResources(memory: LinuxMemory(limit: 1024))))
        hostSpec.linux?.resources?.unified = ["memory.oom.group": "1"]
        let guestSpec = try JSONDecoder().decode(ContainerizationOCI.Spec.self, from: try JSONEncoder().encode(hostSpec))
        let path = FileManager.default.temporaryDirectory.appending(path: "cg2-unified-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        let bundle = try ContainerizationOCI.Bundle.create(path: path, spec: guestSpec)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.configPath)) as? [String: Any]
        let linux = json?["linux"] as? [String: Any]
        let resources = linux?["resources"] as? [String: Any]
        #expect(resources?["unified"] as? [String: String] == ["memory.oom.group": "1"])
    }
}

#endif
