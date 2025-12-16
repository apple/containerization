# Containerization

The Containerization package allows applications to use Linux containers.
Containerization is written in [Swift](https://www.swift.org) and uses [Virtualization.framework](https://developer.apple.com/documentation/virtualization) on Apple silicon.

> **Looking for command line binaries for running containers?**\
> They are available in the dedicated [apple/container](https://github.com/apple/container) repository.

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
`vminitd` provides I/O, signals, and events to the calling process when a process is run.

## Requirements

To build the Containerization package, you need:

- Mac with Apple silicon
- macOS 26
- Xcode 26

Older versions of macOS are not supported. 

## Example Usage

For examples of how to use some of the libraries surface, the cctl executable is a good start. This app is a useful playground for exploring the API. It contains commands that exercise some of the core functionality of the various products, such as:

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

See the [README](/kernel/README.md) in the kernel directory for instructions on how to compile the optimized kernel.

### Kernel Support

Containerization allows user provided kernels but tests functionality starting with kernel version `6.14.9`.

### Pre-built Kernel

If you wish to consume a pre-built kernel, make sure it has `VIRTIO` drivers compiled into the kernel (not merely as modules).

The [Kata Containers](https://github.com/kata-containers/kata-containers) project provides a Linux kernel that is optimized for containers, with all required configuration options enabled. The [releases](https://github.com/kata-containers/kata-containers/releases/) page contains downloadable artifacts, and the image itself (`vmlinux.container`) can be found in the `/opt/kata/share/kata-containers/` directory. 

## Prepare to build package

Install the recommended version of Xcode.

Set the active developer directory to the installed Xcode (replace `<PATH_TO_XCODE>`):
```bash
sudo xcode-select -s <PATH_TO_XCODE>
``` 

Install [Swiftly](https://github.com/swiftlang/swiftly), [Swift](https://www.swift.org), and [Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html):

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

## Building a kernel

If you'd like to build your own kernel please see the instructions in the [kernel directory](./kernel/README.md).

## Documentation

Generate the API documentation for local viewing with:

```bash
make docs
make serve-docs
```

Preview the documentation by running in another terminal:

```bash
open http://localhost:8000/containerization/documentation/
```

## Contributing

Contributions to Containerization are welcomed and encouraged. Please see [CONTRIBUTING.md](/CONTRIBUTING.md) for more information.

## Project Status

Version 0.1.0 is the first official release of Containerization. Earlier versions have no source stability guarantees.

Because the Containerization library is under active development, source stability is only guaranteed within minor versions (for example, between 0.1.1 and 0.1.2). If you don't want potentially source-breaking package updates, you can specify your package dependency using .upToNextMinorVersion(from: "0.1.0") instead.

Future minor versions of the package may introduce changes to these rules as needed.
