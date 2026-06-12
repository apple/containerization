# Containerization Kernel Configuration

This directory includes an optimized kernel configuration to produce a fast and lightweight kernel for container use.

- `config-arm64` includes the kernel `CONFIG_` options.
- `Makefile` includes the kernel version and source package URL.
- `build.sh` scripts the kernel build process.
- `image/` includes the configuration for an image with build tooling.

## Building

1. The build process relies on having the `container` tool installed (https://github.com/apple/container/releases).
2. Run `make`. This should create the image used for building the resulting Linux kernel, and then run a container with that image to perform the kernel build.

The build produces an arch-suffixed kernel image, copied into the repo's `bin/` directory:

- `make` (default) → `vmlinux-arm64` (uncompressed `Image`)
- `make x86_64` → `vmlinuz-x86_64` (compressed `bzImage`, cross-compiled inside the arm64 container)

The `z` suffix on the x86 name follows Linux convention for a compressed kernel image.
