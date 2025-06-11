//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
// All rights reserved.
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

#if os(macOS)
import Virtualization

/// A protocol to implement to convert your interface definition to
/// Virtualization.framework's VZVirtioNetworkDeviceConfiguration.
/// This is the definition Virtualization.framework uses to setup
/// interfaces for virtual machines.
public protocol VZInterface {
    /// Return a valid `VZVirtioNetworkDeviceConfiguration`.
    func device() throws -> VZVirtioNetworkDeviceConfiguration
}

#endif
