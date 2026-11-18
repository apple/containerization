# Memory balloon for VZ virtual machines

Design notes for adding a virtio memory balloon to `VZVirtualMachineInstance`.

## What a balloon is

A virtio-balloon is a paravirtual device that lets the host take memory back from a
running guest, and return it, without a reboot. A driver in the guest kernel cooperates:

- **Inflate**: the host lowers the target. The guest driver allocates pages from the
  guest's own memory and pins them, then reports them to the host, which can reclaim the
  backing physical memory. From inside the guest those pages look "in use".
- **Deflate**: the host raises the target. The driver frees the pages back to the guest.

The guest keeps seeing its configured RAM size. Only the amount usable changes. The guest
needs `CONFIG_VIRTIO_BALLOON`; the repo kernels (`kernel/config-arm64`,
`kernel/config-x86_64`) set it to `y`. A guest without the driver ignores the device.

## What Virtualization.framework exposes

Verified against the MacOSX27.0 SDK headers (macOS 11+).

Before boot:

```swift
config.memorySize = 16.gib()
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
```

After boot:

```swift
let balloon = vm.memoryBalloonDevices
    .compactMap { $0 as? VZVirtioTraditionalMemoryBalloonDevice }.first
balloon?.targetVirtualMachineMemorySize = 8.gib()
```

Semantics from `VZVirtioTraditionalMemoryBalloonDevice.h`:

- `targetVirtualMachineMemorySize` is the amount of memory the guest should keep (not the
  balloon size). Balloon size is `memorySize - target`.
- It starts at `config.memorySize`, which is also the maximum. The balloon can only shrink
  a VM below its configured size, never grow it past it.
- Valid range is `VZVirtualMachineConfiguration.minimumAllowedMemorySize` through
  `memorySize`, in multiples of 1 MiB. Out-of-range values are **silently** rounded down
  and clamped by VZ, not rejected.
- Setting it is a request. The guest acts on it "if at all".
- There is no API to read the actual balloon size. Reading the property returns the target
  that was set.
- The header recommends compacting guest memory first
  (`echo 1 > /proc/sys/vm/compact_memory`) to reduce fragmentation.
- Like other VZ runtime APIs, it should be touched on the VM's queue.

## A target is not a guarantee

Example: 16 GiB VM, 10 GiB in use, target set to 8 GiB. The balloon needs 8 GiB of guest
pages (not 2 GiB):

1. It takes the 6 GiB of free memory first.
2. For the rest, it allocates with flags that permit normal reclaim but not the OOM
   killer, so the guest drops clean page cache, writes back and drops dirty cache, and
   swaps anonymous pages if it has swap.
3. If the remaining memory is truly unreclaimable (anonymous memory with no swap, pinned
   or kernel memory), the balloon stalls short of the target. The memory is not
   relinquished.

Note "used" in `free` often includes page cache, which is reclaimable, so the balloon often
reaches further than the number suggests, at the cost of the guest's file cache.

With `VIRTIO_BALLOON_F_DEFLATE_ON_OOM` (negotiated by most distro kernels) the balloon
gives pages back when the guest is about to OOM, so an over-aggressive target usually
degrades into a partial inflate rather than a kill. That is driver behavior, not a VZ
guarantee.

## Why not set the target very small

The guest cannot pull memory back out of the balloon on demand. Deflation is host
driven; deflate-on-OOM is only a last-resort safety net. A tiny target causes:

- permanent memory pressure and almost no page cache, so reads hit disk and workloads slow
  down (or swap, if there is swap);
- a latency cliff when the workload needs memory, since deflate-on-OOM fires only after
  direct reclaim has already stalled, and is not guaranteed to be in time;
- fragmentation from scattered balloon pages.

The balloon is a dial turned from outside, not a pool the guest borrows from.

## Estimating how much memory a guest needs

Inputs available today through `LinuxContainer.statistics()` (cgroup `memory.current` and
`memory.stat`, built in `vminitd/Sources/Cgroup/Cgroup2Manager.swift`):

- `MemoryStatistics`: `usageBytes`, `limitBytes`, `anon`, `cacheBytes`, `inactiveFile`,
  `slabBytes`, `kernelStackBytes`, swap, page faults, `workingsetRefaultFile/Anon`,
  `pgstealKswapd/Direct/Khugepaged`.

For a single-container VM, `anon + active file + guestMemoryOverhead` is a reasonable
first estimate of the working set. `VMResources.guestMemoryOverhead` is a flat 128 MiB for
the guest kernel and `vminitd` beyond the container limit; the library never applies it
(callers such as `cctl` add it), and `LinuxContainerTests.guestMemoryOverheadIsOptInOnly`
pins that. It is a rough static floor, not a measurement.

What the statistics do not cover: guest-wide `MemAvailable`, PSI, and memory outside the
container cgroup (guest kernel, `vminitd`). There is no balloon state either.

### Memory pressure (PSI)

`/proc/pressure/memory` (Linux 4.20+, `CONFIG_PSI`; also per-cgroup `memory.pressure`):

```
some avg10=0.00 avg60=0.12 avg300=0.05 total=48213
full avg10=0.00 avg60=0.00 avg300=0.00 total=1204
```

- `some`: share of wall time at least one task was stalled on memory (reclaim, refault,
  swap-in, thrashing).
- `full`: share of time all non-idle tasks were stalled.
- `avg*`: moving averages over 10/60/300 s. `total`: cumulative stall in microseconds.

The working-set estimate is a *level* (how much the guest probably needs). Pressure is
*feedback* (whether the current size is actually hurting). The estimate is heuristic and
can be wrong either way; pressure measures the cost directly. A sound policy uses both:
pick the initial target from the estimate plus headroom, then shrink slowly while pressure
stays low and grow quickly when it rises (the approach used by Meta's TMO / senpai).

`workingsetRefaultFile` and `pgstealDirect` are rough pressure proxies already in
`MemoryStatistics`: diffing them between samples gives a usable but noisier signal. Adding
real PSI would take a new vminitd RPC (proto change, `make protos`).

Such a control loop is policy and belongs to the caller, not the library.

## Decisions

1. **No `LinuxContainer` / `LinuxPod` API.** Setting the target is a low-level VMM
   operation. Callers reach it through the existing `withVirtualMachineInstance`
   (`LinuxContainer.swift`, `LinuxPod.swift`) and a method on `VZVirtualMachineInstance`.
2. **The library does nothing smart.** No policy loop, no estimation, no automatic
   shrinking.
3. **Add the balloon device by default** in `VZVirtualMachineInstance.toVZ`. At the default
   target (equal to `memorySize`) it never inflates, so it costs essentially nothing, and a
   guest without the driver ignores it.
4. **Restoring state saved before this change is out of scope.** VZ requires the
   configuration to match on restore, and adding a device changes it.

## Planned `VZVirtualMachineInstance` API

A method that sets the target memory size. It validates and throws instead of relying on
VZ's silent clamping:

- Takes `lock.withLock`, like `pause()` / `resume()`.
- Requires the VM to be in a state where VZ accepts the change (`.running`; whether
  `.paused` is accepted should be tested, not assumed). The error names the actual state.
- Performs the set on the instance's `queue`.
- Throws `ContainerizationError(.invalidArgument)` when the value is not a multiple of
  1 MiB, is below `VZVirtualMachineConfiguration.minimumAllowedMemorySize`, or is above the
  configured memory size (`memoryInBytes` rounded up to MiB, as `toVZ` computes).
- Throws a clear error if the VM has no balloon device.
- The doc comment states that it is a request: the guest may satisfy it partly or never,
  and the actual balloon size cannot be read back.

Optionally, a guest-side compaction step (via `vminitd`) before lowering the target, as the
SDK header recommends.

## Open items

- Whether the cloud-hypervisor backend gets a matching method (it has its own balloon
  device and a REST resize endpoint). Until then callers downcast to
  `VZVirtualMachineInstance`.
- Whether `.paused` VMs accept target changes.
- Whether to add a vminitd RPC returning `/proc/meminfo` and PSI for callers building a
  policy loop.
