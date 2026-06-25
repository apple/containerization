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

extension Kernel {
    /// Build the `init=/sbin/vminitd` Linux kernel command line for the given
    /// rootfs type. Used by both the VZ and cloud-hypervisor backends since
    /// the guest's vminitd init contract is identical across VMMs.
    func linuxCommandline(initialFilesystem: Mount) -> String {
        var args = self.commandLine.kernelArgs

        args.append("init=/sbin/vminitd")
        // rootfs is always mounted read-only.
        args.append("ro")

        switch initialFilesystem.type {
        case "virtiofs":
            args.append(contentsOf: [
                "rootfstype=virtiofs",
                "root=rootfs",
            ])
        case "ext4":
            args.append(contentsOf: [
                "rootfstype=ext4",
                "root=/dev/vda",
            ])
        default:
            fatalError("unsupported initfs filesystem \(initialFilesystem.type)")
        }

        if self.commandLine.initArgs.count > 0 {
            args.append("--")
            args.append(contentsOf: self.commandLine.initArgs)
        }

        return args.joined(separator: " ")
    }
}
