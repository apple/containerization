# CloudHypervisor

A standalone Swift library for driving the [cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) REST API over a Unix domain socket. The package compiles on both macOS and Linux, though `cloud-hypervisor` itself only runs on Linux.

## Dependencies

- [swift-nio](https://github.com/apple/swift-nio): `NIOCore`, `NIOPosix`, `NIOHTTP1`, `NIOConcurrencyHelpers`
- [swift-log](https://github.com/apple/swift-log): `Logging`

There are no transitive dependencies on any other `containerization` library types.

## Usage

```swift
import CloudHypervisor

let client = try CloudHypervisor.Client(
    socketPath: URL(filePath: "/tmp/ch-foo/api.sock")
)

try await client.vmmPing()
try await client.vmCreate(VmConfig(/* ... */))
try await client.vmBoot()
```

### Full example with shared event loop group

```swift
import CloudHypervisor
import NIOPosix

let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
defer { try? group.syncShutdownGracefully() }

let client = try CloudHypervisor.Client(
    socketPath: URL(filePath: "/run/ch/vm0.sock"),
    eventLoopGroup: group
)

let info = try await client.vmInfo()
print(info.state)
```

## Supported Endpoints (v1)

### VMM

- `vmmPing() -> VmmPingResponse` — verify the VMM process is alive
- `vmmShutdown()` — shut down the VMM process
- `vmmInfo() -> VmmInfo` — query VMM-level metadata

### VM Lifecycle

- `vmCreate(_ config: VmConfig)` — define a new VM
- `vmBoot()` — start the VM
- `vmShutdown()` — gracefully shut down the VM
- `vmInfo() -> VmInfo` — query VM state and configuration
- `vmPause()` — pause a running VM
- `vmResume()` — resume a paused VM

### Hotplug

- `vmAddDisk(_ config: DiskConfig) -> PciDeviceInfo` — hot-add a block device
- `vmAddFs(_ config: FsConfig) -> PciDeviceInfo` — hot-add a virtio-fs share
- `vmAddNet(_ config: NetConfig) -> PciDeviceInfo` — hot-add a network device
- `vmAddVsock(_ config: VsockConfig) -> PciDeviceInfo` — hot-add a vsock device
- `vmRemoveDevice(id: String)` — hot-remove a device by ID

## Minimum Supported cloud-hypervisor Version

The package targets the `/api/v1/` REST namespace. It is tested against **cloud-hypervisor v40** and later. Earlier releases may be missing endpoints or use incompatible JSON schemas.

## Error Model

All failures are reported through `CloudHypervisor.Error`:

- `.transport(any Swift.Error)` — a network or NIO-level failure before the HTTP response was received
- `.http(status:body:)` — the server responded with a non-2xx HTTP status; `body` contains the raw response bytes
- `.decoding(any Swift.Error, body:)` — the response had a 2xx status but JSON decoding failed; `body` is the raw bytes for diagnostics
- `.invalidSocketPath(String)` — the URL passed to `Client.init` is not a `file://` URL

Non-2xx responses always produce `.http`, never a decode error, so callers can distinguish protocol-level errors from unexpected payloads.

## Concurrency

`Client` is `Sendable` and all endpoint methods are `async throws`. Each call opens a fresh TCP-over-UDS connection to cloud-hypervisor and closes it when the response is complete.

By default the client creates and owns a `MultiThreadedEventLoopGroup` and shuts it down in `deinit`. If you already have an event loop group (e.g. from NIO or another library), pass it via the `eventLoopGroup:` parameter — in that case the client does **not** shut the group down on `deinit`, leaving lifecycle management to the caller.

## Non-Goals (v1)

- Not a high-level VM orchestration layer — for that, use the `Containerization` library.
- Not exhaustive coverage of cloud-hypervisor's full OpenAPI surface — only the 14 endpoints listed above are implemented; additional endpoints can be added incrementally.
- No connection pooling — a fresh connection is opened per request, which is appropriate for low-volume control-plane use.
- No streaming response bodies — response payloads are buffered in memory before decoding.
