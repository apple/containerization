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

import AccessoryAccess
import AppKit
import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Synchronization

struct Options: ParsableArguments {
    @Option(name: [.customLong("kernel"), .customShort("k")], help: "Kernel binary path, built from kernel/config-arm64", completion: .file(), transform: absolutePath)
    var kernel: String = absolutePath("../../bin/vmlinux-arm64")

    @Option(name: .long, help: "initfs.ext4 path containing vminitd", completion: .file(), transform: absolutePath)
    var initfs: String = absolutePath("../../bin/initfs.ext4")

    @Option(name: [.customLong("image"), .customShort("i")], help: "Image reference to base the container on")
    var imageReference: String = "docker.io/library/alpine:3.20"
}

private func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: path, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
}

@main
struct USBPassthroughExample {
    @MainActor
    static func main() {
        let options = Options.parseOrExit()

        // Accessory Access only works from apps that appear in the Dock.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        Task {
            do {
                try await run(options)
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    static func run(_ options: Options) async throws {
        for (path, hint) in [(options.kernel, "make -C kernel"), (options.initfs, "make init")] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ContainerizationError(.notFound, message: "\(path) not found; build it with `\(hint)` from the repo root")
            }
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("usb-passthrough-example")
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        print("Pulling \(options.imageReference)...")
        let image = try await ImageStore.default.get(reference: options.imageReference, pull: true)
        let rootfs = try await EXT4Unpacker(capacityInBytes: 512.mib())
            .unpack(image, for: .current, at: workDir.appendingPathComponent("rootfs.ext4"))

        let vmm = VZVirtualMachineManager(
            kernel: Kernel(path: URL(fileURLWithPath: options.kernel), platform: .linuxArm),
            initialFilesystem: .block(
                format: "ext4",
                source: options.initfs,
                destination: "/",
                options: ["ro"]
            )
        )
        let bootLog = workDir.appendingPathComponent("boot.log")
        // LinuxContainer doesn't forward extensions, so use a pod.
        let pod = try LinuxPod("usb-passthrough", vmm: vmm) { config in
            config.extensions = [USBPassthrough()]
            config.bootLog = .file(path: bootLog)
        }
        try await pod.addContainer("probe", rootfs: rootfs) { config in
            config.process.arguments = ["/bin/sh", "-c", "while :; do sleep 3600; done"]
        }

        print("Starting VM...")
        try await pod.create()
        do {
            try await pod.startContainer("probe")
            print("VM running. Boot log: \(bootLog.path)")
            try await listen(pod)
        } catch {
            try? await pod.stop()
            throw error
        }
        try await pod.stop()
    }

    static func listen(_ pod: LinuxPod) async throws {
        let listener = Listener(pod: pod)
        let existing: [AAUSBAccessory]
        do {
            existing = try await AAUSBAccessoryManager.shared.registerListener(listener, matchingCriteria: [])
        } catch let error as AAError where error.code == .internalError {
            throw ContainerizationError(
                .internalError,
                message: """
                    Accessory Access refused this process. The com.apple.developer.accessory-access.usb \
                    entitlement is missing or wasn't honored for this signature. Run `make entitlements` \
                    to see what was embedded.
                    """,
                cause: error
            )
        }
        print("Accessory Access listener registered.")
        for accessory in existing {
            listener.usbAccessoryDidConnect(accessory)
        }

        print("Attach a USB device to this app from the Accessory Access menu bar item. Ctrl-C to quit.")
        let signals = AsyncSignalHandler.create(notify: [SIGINT])
        for await _ in signals.signals {
            break
        }
        signals.cancel()
        // A second Ctrl-C kills the process.
        signal(SIGINT, SIG_DFL)

        print("Shutting down...")
        await AAUSBAccessoryManager.shared.unregisterListener(listener)
    }
}

/// Attaches granted accessories to the VM and checks that the guest sees them.
final class Listener: NSObject, AAUSBAccessoryListener, Sendable {
    private let pod: LinuxPod
    private let attached = Mutex<[UInt64: UUID]>([:])
    private let probeCount = Atomic<Int>(0)

    init(pod: LinuxPod) {
        self.pod = pod
    }

    func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        Task { await self.attach(accessory) }
    }

    func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        Task { await self.detach(accessory) }
    }

    private func attach(_ accessory: AAUSBAccessory) async {
        let id = DeviceID(accessory)
        print("\(id): connected, attaching")
        do {
            let uuid = try await self.pod.withVirtualMachineInstance { vm in
                guard let vz = vm as? VZVirtualMachineInstance else {
                    throw ContainerizationError(.unsupported, message: "USB passthrough requires the Virtualization.framework backend")
                }
                return try await vz.attachUSBDevice(accessory)
            }
            self.attached.withLock { $0[accessory.registryID] = uuid }
            print("\(id): attached as \(uuid)")
            try await self.probe(id)
        } catch {
            print("\(id): \(error)")
        }
    }

    private func detach(_ accessory: AAUSBAccessory) async {
        let id = DeviceID(accessory)
        guard let uuid = self.attached.withLock({ $0.removeValue(forKey: accessory.registryID) }) else {
            return
        }
        do {
            try await self.pod.withVirtualMachineInstance { vm in
                try await (vm as? VZVirtualMachineInstance)?.detachUSBDevice(uuid)
            }
            print("\(id): detached")
        } catch {
            print("\(id): detach: \(error)")
        }
    }

    /// Waits up to 10s for the device in the guest's sysfs and /dev.
    private static let probeScript = """
        for _ in $(seq 1 10); do
          for d in /sys/bus/usb/devices/*; do
            [ "$(cat "$d/idVendor" 2>/dev/null)" = "$1" ] || continue
            [ "$(cat "$d/idProduct" 2>/dev/null)" = "$2" ] || continue
            node=$(printf /dev/bus/usb/%03d/%03d "$(cat "$d/busnum")" "$(cat "$d/devnum")")
            echo "  sysfs: $d ($(cat "$d/product" 2>/dev/null))"
            [ -e "$node" ] || { echo "  missing $node"; exit 1; }
            echo "  node:  $node"
            exit 0
          done
          sleep 1
        done
        exit 1
        """

    private func probe(_ id: DeviceID) async throws {
        let n = self.probeCount.add(1, ordering: .relaxed).newValue
        let process = try await self.pod.execInContainer("probe", processID: "probe-\(n)") { config in
            config.arguments = ["/bin/sh", "-c", Self.probeScript, "probe", id.vendor, id.product]
            config.stdout = StdoutWriter()
            config.stderr = StdoutWriter()
        }
        try await process.start()
        let status = try await process.wait()
        try await process.delete()
        print(status.exitCode == 0 ? "\(id): PASS, visible in guest" : "\(id): FAIL, not visible in guest")
    }
}

/// Vendor and product IDs from the device descriptor, formatted like sysfs.
struct DeviceID: Sendable, CustomStringConvertible {
    let vendor: String
    let product: String

    init(_ accessory: AAUSBAccessory) {
        let data = accessory.deviceDescriptorData
        // idVendor and idProduct are little-endian at offsets 8 and 10.
        func word(_ offset: Int) -> String {
            guard data.count >= offset + 2 else {
                return "????"
            }
            let lo = UInt16(data[data.startIndex + offset])
            let hi = UInt16(data[data.startIndex + offset + 1])
            return String(format: "%04x", hi << 8 | lo)
        }
        self.vendor = word(8)
        self.product = word(10)
    }

    var description: String {
        "\(self.vendor):\(self.product)"
    }
}

struct StdoutWriter: Writer {
    func write(_ data: Data) throws {
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    func close() throws {
        return
    }
}
