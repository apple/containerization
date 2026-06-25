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
import CloudHypervisor

/// Extension hook for `CHVirtualMachineInstance` lifecycle. Append conforming
/// types to `Configuration.extensions` to participate in VM setup and
/// teardown without subclassing.
///
/// All methods have no-op defaults so a conforming type only needs to
/// implement the hooks it actually cares about.
public protocol CHInstanceExtension: Sendable {
    /// Mutate the cloud-hypervisor `VmConfig` before the VM is created.
    /// Called by `start()` after the base config is built but before
    /// `vm.create` is dispatched to the VMM.
    func configureCH(_ config: inout CloudHypervisor.VmConfig) throws

    /// Called once the VM has been created and booted but before
    /// `start()` returns to the caller.
    func didCreate(_ instance: CHVirtualMachineInstance) throws

    /// Called from `stop()` before the VM is shut down. Errors are
    /// best-effort — `stop()` swallows them.
    func willStop(_ instance: CHVirtualMachineInstance) async throws
}

extension CHInstanceExtension {
    public func configureCH(_ config: inout CloudHypervisor.VmConfig) throws {}
    public func didCreate(_ instance: CHVirtualMachineInstance) throws {}
    public func willStop(_ instance: CHVirtualMachineInstance) async throws {}
}
#endif
