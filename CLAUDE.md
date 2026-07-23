# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build / Test / Format

The project is built via `make`, not directly with `swift build`. Two Swift packages live in this repo: the root package (Containerization libraries + `cctl` + macOS-only integration binary) and `vminitd/` (the Linux guest init system, compiled as a static musl binary inside the Linux dev container via the apple/`container` CLI — see `make vminitd`).

- `make all` — build everything (`containerization` + `vminitd` + `init.ext4` rootfs in `bin/`). Default `BUILD_CONFIGURATION=debug`; pass `release` (or use `make release`) for optimized builds.
- `make containerization` — build just the host-side Swift package (skips vminitd).
- `make vminitd` — build vminitd / vmexec only. On macOS this runs `swift build --swift-sdk …-swift-linux-musl` *inside the Linux dev container* via the `container` CLI (the cloud-hypervisor build model), producing static musl binaries at `vminitd/bin/`; no host Swiftly/SDK needed. `make linux-build LIBC=glibc` builds via a Linux dev container.
- `make test` — unit tests with code coverage. `make coverage` regenerates the coverage report.
- `make integration` — runs `bin/containerization-integration`. Requires an in-repo kernel under `bin/` (`bin/vmlinux-arm64` on arm64, `bin/vmlinuz-x86_64` or `bin/vmlinux-x86_64` on x86_64); if absent, run `make fetch-default-kernel` to download the Kata-provided kernel for the host arch.
- Single test: `swift test --filter ContainerizationOCITests.ReferenceTests/testParsing` (Swift Testing / XCTest filter syntax). Targets are listed in `Package.swift`.
- `make linux-test` — runs `swift test` inside the Linux dev container (requires the `container` CLI from apple/container).
- `make linux-build` — builds the host-side Swift package (incl. `cctl`, `Containerization`, and `CloudHypervisor`) inside the same Linux dev container. Use this to validate Linux portability of host-side code; the resulting `cctl` is what the cloud-hypervisor backend ships behind.
- `make linux-integration` — runs the cross-platform integration suite against a real cloud-hypervisor VM inside the dev container (nested virt via apple/container's `--virtualization`). Requires a KVM-capable kernel at `kernel/vmlinux-arm64` (or `kernel/vmlinuz-x86_64` on x86_64 hosts) — build via `make -C kernel`; the kata-fetched kernel doesn't include KVM. Also requires `make fetch-cloud-hypervisor` and `make linux-build` to have been run first. Linux runs only the cross-platform subset (`process true`/`false`/`echo hi`); the macOS suite is unchanged.
- `make fetch-cloud-hypervisor` — downloads the static `cloud-hypervisor` v52.0 (aarch64) binary into `bin/cloud-hypervisor` for the Linux integration tests.
- `make build-cloud-hypervisor` / `make build-virtiofsd` — build patched `cloud-hypervisor` / `virtiofsd` from sources you have cloned into `.local/cloud-hypervisor` and `.local/virtiofsd` respectively. There is no fetch target — clone the upstream repos at the revision you want pinned. `build-virtiofsd` applies `scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch` and is idempotent. Both run inside the same Linux dev container as `linux-integration` so the resulting binaries are aarch64-linux-gnu.
- `make dist-x86_64` — assembles `bin/containerization-x86_64-<sha>.tar.gz` (cctl + cloud-hypervisor + virtiofsd + initfs.ext4 + kernel) for x86_64 Linux deployment, cross-compiled inside the aarch64 dev container via the Static Linux SDK (Swift) and `cargo zigbuild` (Rust). Prereqs: `.local/cloud-hypervisor` and `.local/virtiofsd` source checkouts (clone deliberately — no fetch target), and an x86_64 kernel built via `make -C kernel TARGET_ARCH=x86_64`. Per-stage rebuild env vars: `REBUILD_VMINITD=1`, `REBUILD_INITFS=1`, `REBUILD_CH=1`, `REBUILD_VIRTIOFSD=1`; cctl x86 always rebuilds. **Full pipeline, toolchain rationale, and troubleshooting in `docs/x86_64-build.md`.** The orchestrator is `scripts/build-dist-x86_64.sh`.
- `make fmt` — applies `.swift-format` and refreshes license headers via hawkeye.
- `make check` — formatting + license-header lint (this is what the pre-commit hook runs). Uses `.swift-format-nolint` for stricter linting.
- `make pre-commit` — installs `scripts/pre-commit.fmt` as a git pre-commit hook.
- `make protos` — regenerates `Sources/Containerization/SandboxContext/SandboxContext.{pb,grpc}.swift` from the `.proto`. Touch this whenever the proto changes; never hand-edit the generated files.
- `make init` / `make init-image` — `init` compiles the guest and builds `bin/initfs.ext4` (+ a rootfs tar) inside the dev container via `scripts/build-initfs.sh` (mkfs + loop mount, with a `mke2fs -d` fallback), then `init-image` creates the `vminit:latest` OCI image from the tar with the native `cctl` (`cctl rootfs create --rootfs <tar> --image vminit:latest`). CI splits these: a Linux container job builds the initfs artifact, the macOS job runs `init-image`. Building the guest on macOS requires the apple/`container` CLI — there is no host Swiftly / Static Linux SDK setup step anymore.

`WARNINGS_AS_ERRORS=true` is the default for both packages. Don't disable it casually — CI builds with it on.

## Architecture

This is a **Swift library package** (not a CLI tool) that lets applications run Linux containers on Apple silicon by spawning a lightweight VM per container via `Virtualization.framework`. The corresponding end-user CLI lives in [`apple/container`](https://github.com/apple/container) and is **not** part of this repo. `cctl` here is a playground/example binary, not the shipping product.

### The host ↔ guest split

Every Linux container runs inside its own VM. The boundary between host (macOS) and guest (Linux) is the central architectural fact:

- **Host side** (`Sources/`, `macOS` platform): orchestrates VMs through `Virtualization.framework` (`VZVirtualMachineInstance.swift`, `VZVirtualMachine+Helpers.swift`). The user-facing entry points are `LinuxContainer` (one container per VM) and `LinuxPod` (multiple containers in one VM, experimental). These build a `VMConfiguration`, boot the VM with the chosen `Kernel` and a rootfs containing `vminitd`, then drive the guest via gRPC.
- **Guest side** (`vminitd/`, Linux platform): `vminitd` is PID 1 inside the VM. It exposes a gRPC service over **vsock** (default port `1024`) defined by `Sources/Containerization/SandboxContext/SandboxContext.proto`. `VminitdCore` implements that service: launching container processes, handling stdio over vsock, signal/event delivery, cgroups, mounts, and process lifecycle. By default it launches workloads via `vmexec` (a small helper that runs a single process inside the guest namespace); `runc` is used only when an OCI runtime path is supplied.

The proto is the contract between the two halves. **The `.pb.swift` and `.grpc.swift` files in `SandboxContext/` are generated** — regenerate via `make protos` after changing `SandboxContext.proto`. Both host and guest depend on the same generated Swift via the path-dependency wiring in `vminitd/Package.swift` (`containerization` is a sibling path package).

### VMM backends

`Containerization` abstracts the VMM behind `VirtualMachineManager` / `VirtualMachineInstance`. Two backends ship in this repo, both inside the same `Containerization` target but gated by `#if`:

- **macOS**: `VZVirtualMachineManager` / `VZVirtualMachineInstance` (`VZ*` files, `#if os(macOS)`). Drives `Virtualization.framework` directly.
- **Linux**: `CHVirtualMachineManager` / `CHVirtualMachineInstance` (`CH*` files plus `CHProcess`, `VirtiofsdProcess`, `Vsock+Linux`, all `#if os(Linux)`). One `cloud-hypervisor` subprocess per VM, REST-on-UDS control plane via the standalone [`CloudHypervisor`](./Sources/CloudHypervisor) Swift package, virtio-blk / virtio-fs (one `virtiofsd` per share) / TAP / vsock for the data plane. Same `Vminitd` guest contract as VZ — only the host-side VMM differs.

The `CloudHypervisor` library is a thin NIO-based HTTP/1.1-over-UDS client targeting cloud-hypervisor's REST API. It compiles on both platforms (so it can be unit-tested on macOS without a real cloud-hypervisor binary), but is only consumed by the Linux backend at runtime.

**Sandbox env vars.** `CHProcess` and `VirtiofsdProcess` default to the upstream-secure spawn flags. Per-component opt-outs:

- `CONTAINERIZATION_NO_CH_SECCOMP=1` — launch cloud-hypervisor with `--seccomp false`.
- `CONTAINERIZATION_NO_VIRTIOFSD_SANDBOX=1` — launch virtiofsd with `--sandbox none`.

Both flags emit a one-line `logger.warning` at start so a relaxed-sandbox VM is loud in the host log. The legacy alias `CONTAINERIZATION_RELAXED_SANDBOX=1` continues to flip both at once. These are required inside apple/container's `--virtualization` dev container, where the host seccomp profile SIGSYS-kills both binaries; `make linux-integration` sets the legacy alias automatically. Leave them unset in production deployments where the host policy lets CH/virtiofsd run unmolested.

### Library targets (`Sources/`)

These are independently consumable Swift modules. Keep their dependencies narrow:

- `Containerization` — the top-level orchestration layer (`LinuxContainer`, `LinuxPod`, `VMConfiguration`, `Vminitd` gRPC client wrapper, mounts, networking, sockets, image unpacking). Hosts both the macOS (VZ) and Linux (CH) VMM backends behind `#if os(...)`.
- `CloudHypervisor` — standalone NIO-based HTTP/1.1-over-UDS client targeting cloud-hypervisor's REST API. Cross-platform (compiles on macOS for unit tests; consumed at runtime only by the Linux side of `Containerization`).
- `ContainerizationOCI` — OCI image spec types, registry client (push/pull/auth), local OCI layout, content store. Used host-side for image management.
- `ContainerizationEXT4` — pure-Swift ext4 reader/formatter; used to build container rootfs blocks (`bin/initfs.ext4`).
- `ContainerizationArchive` — Swift wrapper around vendored libarchive headers (`Sources/ContainerizationArchive/CArchive`, refreshable via `make update-libarchive-source`). Links system `libarchive`, `lzma`, `bz2`, `z`, plus zstd via SwiftPM.
- `ContainerizationNetlink` — netlink socket bindings (used by vminitd for in-guest network configuration).
- `ContainerizationOS` — POSIX/Darwin/Linux platform shims (`Command`, `Terminal`, `Socket`, signal handling, mount syscalls, keychain). Cross-platform.
- `ContainerizationIO` — small NIO-flavored stream/reader utilities.
- `ContainerizationExtras`, `ContainerizationError`, `CShim` — shared helpers and a tiny C bridge.

`Sources/Integration/` is the macOS-only `containerization-integration` binary (the integration test runner; it is not a `testTarget`, it's an `executableTarget` that's invoked by `make integration`). Unit `testTarget`s live under `Tests/`.

### vminitd internals (`vminitd/Sources/`)

- `VminitdCore/Server+GRPC.swift` is the bulk of the guest agent — it implements every RPC declared in `SandboxContext.proto`.
- `ManagedContainer.swift` / `ManagedProcess.swift` launch container processes via `vmexec` by default; `VminitdCore/Runc/` plus `RuncProcess.swift` shell out to `runc` only when an OCI runtime path is supplied. `ProcessSupervisor` reaps and dispatches exit events.
- `Cgroup/` handles cgroup v2 setup. `LCShim/` and `CVersion/` are small C bridges (the latter injects `GIT_COMMIT`/`GIT_TAG`/`BUILD_TIME` at compile time).
- `vmexec` runs a single container process inside the guest namespace and is what `vminitd` execs to launch container workloads.

## Conventions

- **License headers are required** on every Swift file. `make check-licenses` runs hawkeye against `scripts/license-header.txt`. New files: run `make update-licenses` (or `make fmt`) before committing.
- **Formatting**: `.swift-format` (line length 180, 4-space indent). The lint config (`.swift-format-nolint`) is what CI enforces. `NeverForceUnwrap`, `NeverUseForceTry`, and `NeverUseImplicitlyUnwrappedOptionals` are all on — don't introduce `!` / `try!`.
- **Package isolation**: prefer adding code to the smallest applicable module. Don't pull `Containerization` into `ContainerizationOCI` or similar — the leaf modules are intentionally light so they can be consumed standalone.
- **`SandboxContext.proto` is excluded from the `Containerization` target** (see `Package.swift`). The generated `.pb.swift` / `.grpc.swift` files are checked in.
- **Squash-and-merge**: PRs land as a single commit, so the PR title/body becomes the commit message — write it accordingly. Commits must be signed (per `CONTRIBUTING.md`).

## Requirements

Apple silicon Mac, macOS 26, Xcode 26. The host-side build uses Xcode's Swift toolchain (`/usr/bin/swift`); the Linux guest is built inside the dev container, so the apple/`container` CLI is required (see the README). The pinned Swift version (`.swift-version`, currently `6.3.0`) tags the dev image and the CI Swift Linux container. Older macOS releases are not supported.
