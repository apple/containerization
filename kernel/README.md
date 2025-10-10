# Containerization Kernel Configuration

This directory includes an optimized kernel configuration to produce a fast and lightweight kernel for container use.

- `config-arm64` includes the kernel `CONFIG_` options.
- `Makefile` includes the kernel version and source package url.
- `build.sh` scripts the kernel build process.
- `image/` includes the configuration for an image with build tooling.

## Building

1. Build the `Containerization` project by running `make` in the root of the repository.
2. Place a kernel you want to use in the `bin/vmlinux` directory of the repository.

    a. This kernel will be used to launch the build container.

    b. To fetch a default kernel run `make fetch-default-kernel` in the root of the repository.
3. Run `make` in the `/kernel` directory. 

A `kernel/vmlinux` will be the result of the build.
1. The build process relies on having the `container` tool installed (https://github.com/apple/container/releases).
2. Run `make`. This should create the image used for building the resulting Linux kernel, and then run a container with that image to perform the kernel build.

A `kernel/vmlinux` file will be the result of the build.
