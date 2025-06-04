# Containerization

The Containerization package allows applications to use Linux containers.
Containerization is written in [Swift](https://www.swift.org) and uses [Virtualization.framework](https://developer.apple.com/documentation/virtualization) on Apple Silicon.

Containerization provides APIs to:
- Manage OCI images.
- Interact with remote registries.
- Create and populate ext4 file systems.
- Interact with the Netlink socket family.
- Create an optimized Linux kernel for fast boot times.
- Spawn lightweight virtual machines.
- Manage the runtime environment of virtual machines.
- Spawn and interact with containerized processes.
- Use Rosetta 2 for executing x86_64 processes on Apple Silicon.

Please view the [API documentation]() for information on the Swift packages that Containerization provides.

## Design

Containerization executes each Linux container inside of its own lightweight virtual machine. Clients can create dedicated IP addresses for every container to remove the need for individual port forwarding. Containers achieve sub-second start times using an optimized [Linux kernel configuration](/kernel) and a minimal root filesystem with a lightweight init system.

[vminitd](/vminitd) is a small init system, which is a subproject within Containerization.
`vminitd` is spawned as the initial process inside of the virtual machine and provides a GRPC API over vsock.
The API allows the runtime environment to be configured and containerized processes to be launched.
`vminitd` provides I/O, signals, and events to the calling process when a process is ran.

## Requirements

You need an Apple Silicon Mac to build and run Containerization.

To build the Containerization package, your system needs either:

- macOS 15 or newer and Xcode 17 beta
- macOS 16 Developer Preview.

Applications built using the package will run on macOS Sequoia or later, but the following features are not available on macOS Sequoia:

- Non-isolated container networking - with macOS Sequoia, containers on the same vmnet network cannot communicate with each other

## Linux kernel

A Linux kernel is required for spawning light weight virtual machines on macOS.
Containerization provides an optimized kernel configuration located in the [kernel](./kernel) directory.

This directory includes a containerized build environment to easily compile a kernel for use with Containerization.

The kernel configuration is a minimal set of features to support fast start times and a light weight environment.

While this configuration will work for the majority of workloads we understand that some will need extra features.
To solve this Containerization provides first class APIs to use different kernel configurations and versions on a per container basis.
This enables containers to be developed and validated across different kernel versions.

See the [README](/kernel/README.md) in the kernel directory for instruction on how to compile the optimized kernel.

### Pre-build Kernel

If you wish to consume a pre-built kernel it must have `VIRTIO` drivers compiled into the kernel, not as modules.

The [Kata Containers](https://github.com/kata-containers/kata-containers) project provides an optimized kernel for containers with all the required configuration options enabled provided on the [releases](https://github.com/kata-containers/kata-containers/releases/) page.

A kernel image named `vmlinux.container` can be found in the `/opt/kata/share/kata-containers/` directory of the release artifacts.

## Build the package

Install Swiftly, [Swift](https://www.swift.org), and [Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html):

```bash
make cross-prep
```

If you use a custom terminal application, you may need to move this command from `.zprofile` to `.zshrc` (replace `<USERNAME>`):
```bash
# Added by swiftly
. "/Users/<USERNAME>/.swiftly/env.sh"
```

Restart the terminal application. Ensure this command returns `/Users/<USERNAME>/.swiftly/bin/swift` (replace `<USERNAME>`):
```bash
which swift
```

If you've installed or used a Static Linux SDK previously, you may need to remove older SDK versions from the system (replace `<SDK-ID>`):
```
swift sdk list
swift sdk remove <SDK-ID>
```

Build Containerization from sources and run basic and integration tests:

```bash
make all test integration
```

## Protobufs

Containerization depends on specific versions of `grpc-swift` and `swift-protobuf`. You can install them and re-generate RPC interfaces with:

```bash
make protos
```

## Documentation

Generate the API documentation for local viewing with:

```bash
make docs
make serve-docs
```

Preview the documentation by running in another terminal:

```bash
open http://localhost:8000/documentation/
```

## Contributing 

Contributions to Containerization are welcomed and encouraged. Please see [CONTRIBUTING.md](/CONTRIBUTING.md) for more information.
