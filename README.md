# Containerization

The Containerization package allows applications to use Linux containers.
Containerization is written in [Swift](https://www.swift.org) and uses [Virtualization.framework](https://developer.apple.com/documentation/virtualization) on Apple silicon.

Containerization provides APIs to:

- [Manage OCI images](./Sources/ContainerizationOCI/).
- [Interact with remote registries](./Sources/ContainerizationOCI/Client/).
- [Create and populate ext4 file systems](./Sources/ContainerizationEXT4/).
- [Interact with the Netlink socket family](./Sources/ContainerizationNetlink/).
- [Create an optimized Linux kernel for fast boot times](./kernel/).
- [Spawn lightweight virtual machines and manage the runtime environment](./Sources/Containerization/LinuxContainer.swift).
- [Spawn and interact with containerized processes](./Sources/Containerization/LinuxProcess.swift).
- Use Rosetta 2 for running linux/amd64 containers on Apple silicon.

Please view the [API documentation](https://apple.github.io/containerization/documentation/) for information on the Swift packages that Containerization provides.

## Design

Containerization executes each Linux container inside of its own lightweight virtual machine. Clients can create dedicated IP addresses for every container to remove the need for individual port forwarding. Containers achieve sub-second start times using an optimized [Linux kernel configuration](/kernel) and a minimal root filesystem with a lightweight init system.

[vminitd](/vminitd) is a small init system, which is a subproject within Containerization.
`vminitd` is spawned as the initial process inside of the virtual machine and provides a GRPC API over vsock.
The API allows the runtime environment to be configured and containerized processes to be launched.
`vminitd` provides I/O, signals, and events to the calling process when a process is ran.

## Requirements

You need an Apple silicon Mac to build and run Containerization.

To build the Containerization package, your system needs either:

- macOS 15 or newer and Xcode 26 beta
- macOS 26 beta or newer

Applications built using the package will run on macOS 15 or later, but the following features are not available on macOS 15:

- Non-isolated container networking - with macOS 15, containers on the same vmnet network cannot communicate with each other

## Example Usage

For examples of how to use some of the libraries surface, the cctl executable is a good start. This tools primary job is as a playground to trial out the API. It contains commands that exercise some of the core functionality of the various products, such as:

1. [Manipulating OCI images](./Sources/cctl/ImageCommand.swift)
2. [Logging in to container registries](./Sources/cctl/LoginCommand.swift)
3. [Creating root filesystem blocks](./Sources/cctl/RootfsCommand.swift)
4. [Running simple Linux containers](./Sources/cctl/RunCommand.swift)

## Linux kernel

A Linux kernel is required for spawning lightweight virtual machines on macOS.
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

## Prepare to build package

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

```bash
swift sdk list
swift sdk remove <SDK-ID>
```

## Build the package

Build Containerization from sources:

```bash
make all
```

## Test the package

After building, run basic and integration tests:

```bash
make test integration
```

A kernel is required to run integration tests.
If you do not have a kernel locally for use a default kernel can be fetched using the `make fetch-default-kernel` target.

Fetching the default kernel only needs to happen after an initial build or after a `make clean`.

```bash
make fetch-default-kernel
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

## Project Status

Version 0.1.0 is the first official release of Containerization. Earlier versions have no source stability guarantees.

Because the Containerization library is under active development, source stability is only guaranteed within minor versions (e.g. between 0.1.1 and 0.1.2). If you don't want potentially source-breaking package updates, you can specify your package dependency using .upToNextMinorVersion(from: "0.1.0") instead.

Future minor versions of the package may introduce changes to these rules as needed.
