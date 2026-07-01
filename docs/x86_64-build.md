# x86_64 Deployment Build

`make dist-x86_64` produces a self-contained x86_64 Linux deployment tarball
at `bin/containerization-x86_64-<sha>.tar.gz`. The build runs entirely inside
the aarch64 Linux dev container — there is no host tooling requirement beyond
`make`, `container`, and the prerequisites the dev image installs.

The tarball ships everything needed to run a Containerization VM on an x86_64
Linux host: the `cctl` host binary, the `cloud-hypervisor` VMM, the
`virtiofsd` filesystem daemon, an x86_64 Linux kernel, and an `initfs.ext4`
guest rootfs containing `vminitd` + `vmexec`.

`cctl`, `cloud-hypervisor`, and `vminitd`/`vmexec` are statically linked
against musl, so they run on any x86_64 Linux. **`virtiofsd` is dynamically
linked against glibc 2.35+**; the deployment host must provide glibc
≥ 2.35 (Ubuntu 22.04 / Debian 12 / RHEL 9 era) plus `libseccomp.so.2` and
`libcap-ng.so.0`. Both are present by default on essentially every server
distro shipped in the last few years.

## Prerequisites

Before the first `make dist-x86_64`:

1. **Source checkouts under `.local/`** — pinned by you, not fetched by the
   build. There is no fetch target; clone the revision you want shipped:

   ```sh
   git clone -b v52.0 https://github.com/cloud-hypervisor/cloud-hypervisor \
       .local/cloud-hypervisor
   git clone https://gitlab.com/virtio-fs/virtiofsd .local/virtiofsd
   ```

2. **An x86_64 kernel** at `kernel/vmlinuz-x86_64` (preferred) or
   `kernel/vmlinux-x86_64`. Build via `make -C kernel TARGET_ARCH=x86_64`.
   The build fails hard if neither exists — a tarball without a kernel is
   not usable.

3. **The Linux dev image.** `dist-x86_64` depends on the `linux-image`
   make target, so the `container build` cache handles this automatically;
   the first run takes a few minutes, subsequent runs are seconds.

The dev image (`images/linux-dev/Dockerfile`) bundles Swiftly, the Static
Linux SDK, the Rust toolchain (with `cargo-zigbuild`), a prebuilt
`/opt/cross-x86_64-musl/` prefix containing zlib, xz, bzip2, libarchive,
libcap-ng, and libseccomp built static-musl for x86_64, and a sibling
`/opt/cross-x86_64-gnu/` prefix containing libcap-ng and libseccomp built
as glibc-dynamic shared libraries for virtiofsd's link step.
`scripts/build-musl-x86_64-deps.sh` and `scripts/build-glibc-x86_64-deps.sh`
produce these prefixes at image build time.

## Running the build

```sh
make dist-x86_64
```

Drives `scripts/build-dist-x86_64.sh` inside the dev container via the
`linux_run` macro. The container bind-mounts the repo at `/workspace`, so
all build outputs land back on the host under `bin/dist-x86_64/`.

## Pipeline

The script runs five build stages plus a packaging stage. Each build stage
is gated by a freshness check (see [Rebuild gating](#rebuild-gating)) so
unchanged components are skipped on subsequent runs.

1. **`cctl` cross-compile to x86_64-linux-musl.**
   `swift build --swift-sdk x86_64-swift-linux-musl --product cctl`. Always
   runs — this is the artifact under iteration, and Swift's incremental
   build is a near-no-op when nothing changed.

2. **`vminitd` + `vmexec` cross-compile to x86_64-linux-musl.**
   `make -C vminitd LIBC=musl MUSL_ARCH=x86_64`. The guest agent and
   process launcher; both run inside the VM as PID 1's children.

3. **`cloud-hypervisor` cross-compile to x86_64-unknown-linux-musl.**
   `cargo zigbuild --target x86_64-unknown-linux-musl --bin cloud-hypervisor`
   from `.local/cloud-hypervisor`.

4. **`virtiofsd` cross-compile to x86_64-unknown-linux-gnu.2.35.**
   `cargo zigbuild --target x86_64-unknown-linux-gnu.2.35` from
   `.local/virtiofsd`, with `scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch`
   applied first. The patch is idempotent — applied if missing, skipped if
   already present, fails hard if it can't be applied cleanly. Unlike the
   other three host binaries, virtiofsd is **glibc-dynamic**: it expects
   the deployment host to provide glibc ≥ 2.35, `libseccomp.so.2`, and
   `libcap-ng.so.0`. Link-time `.so` files come from
   `/opt/cross-x86_64-gnu/`.

5. **`initfs.ext4` packaging.**
   A native aarch64 `cctl` is built (Swift release) and used as the packer:
   `cctl rootfs create --vminitd … --vmexec …` writes a ready-to-mount
   ext4 image with the x86_64 guest binaries inside. The native build
   only runs when this stage runs.

6. **Stage and tar.** Always runs. Lays out the staging tree at
   `bin/dist-x86_64/<dist-name>/`:

   ```
   <dist-name>/
   ├── bin/
   │   ├── cctl
   │   ├── cloud-hypervisor
   │   └── virtiofsd
   ├── kernel/
   │   └── vmlinuz-x86_64        # or vmlinux-x86_64, whichever was found
   └── initfs.ext4
   ```

   Then `tar -czf bin/<dist-name>.tar.gz`.

## Rebuild gating

By default, every stage skips when its output is up-to-date. Each freshness
check has a corresponding `REBUILD_*=1` environment variable that forces
the stage to rerun.

| Stage | Skip condition | Force rebuild |
| --- | --- | --- |
| `cctl` x86 cross | (never skipped — always runs) | n/a |
| `vminitd` + `vmexec` | both binaries exist under `bin/dist-x86_64/` AND nothing under `vminitd/Sources/`, `vminitd/Package.swift`, or `Sources/Containerization/SandboxContext/` is newer than them | `REBUILD_VMINITD=1` |
| `cloud-hypervisor` | `bin/dist-x86_64/cloud-hypervisor` exists | `REBUILD_CH=1` |
| `virtiofsd` | `bin/dist-x86_64/virtiofsd` exists | `REBUILD_VIRTIOFSD=1` |
| `initfs.ext4` | exists AND is newer than both staged `vminitd` and `vmexec` (also implicitly skipped when `vminitd` was skipped) | `REBUILD_INITFS=1` |
| native aarch64 `cctl` | only built when `initfs.ext4` is being rebuilt | `REBUILD_INITFS=1` |
| stage tree + tar | (always runs) | n/a |

The freshness checks intentionally use binary presence and source mtimes
rather than content hashing — fast to evaluate, easy to bypass with `touch`
or `rm`. There is no global "rebuild everything" switch by design; force
the specific component you want, or `rm -rf bin/dist-x86_64/` for a full
clean rebuild.

`cloud-hypervisor` and `virtiofsd` only check binary presence (not source
mtime against `.local/`). The pinned-source convention assumes you opt
into rebuilds explicitly — the `REBUILD_CH=1` / `REBUILD_VIRTIOFSD=1`
escape hatches exist for exactly that case. Walking the full Rust source
tree on every run was the alternative; not worth the cost.

### Common rebuild scenarios

- **Iterating on host-side `cctl` or `Containerization` Swift code:** just
  `make dist-x86_64`. Only the x86 cctl rebuild runs (and tar).
- **Touched `vminitd` source or the proto:** `REBUILD_VMINITD=1` is
  picked up automatically by mtime; `make dist-x86_64`. `vminitd` and
  `initfs.ext4` rebuild.
- **Pulled new `.local/cloud-hypervisor`:** `REBUILD_CH=1 make dist-x86_64`.
- **Pulled new `.local/virtiofsd`:** `REBUILD_VIRTIOFSD=1 make dist-x86_64`.
- **Suspect a stale artifact:** `rm -rf bin/dist-x86_64 && make dist-x86_64`
  for a full clean rebuild.

## Cross-compilation toolchain

Two cross toolchains live side-by-side in the dev image. `cctl`,
`vminitd`/`vmexec`, and `cloud-hypervisor` target `x86_64-linux-musl` and
ship statically linked so the artifacts are host-libc independent.
`virtiofsd` targets `x86_64-linux-gnu.2.35` and ships dynamically linked;
the deployment host provides glibc, libseccomp, and libcap-ng.

- **Swift** uses Apple's Static Linux SDK (`x86_64-swift-linux-musl`),
  installed by `make cross-prep` at dev-image build time. The same SDK
  is used for both `cctl` and `vminitd` cross-builds.
- **Rust C cross-compiler is Zig.** For musl stages, `zig cc -target
  x86_64-linux-musl` is wrapped as `x86_64-linux-musl-{gcc,g++,ar,ranlib,strip}`.
  For virtiofsd, parallel `x86_64-linux-gnu-*` wrappers dispatch to
  `zig cc -target x86_64-linux-gnu.2.35`, plus an `x86_64-linux-gnu-ld`
  wrapper backed by LLVM's `ld.lld` (apt-installed). The `ld` wrapper
  is needed because libtool's shared-library detection probes the
  linker with `-m elf_x86_64`; the host's aarch64 `/usr/bin/ld`
  rejects that and would silently disable `.so` emission. The gnu
  `gcc`/`g++` wrappers intercept `-print-prog-name=ld` so libtool
  discovers the cross-ld wrapper instead of the host linker. The
  pinned `.2.35` glibc baseline determines the minimum host glibc;
  bumping it requires editing the wrapper scripts under
  `images/linux-dev/wrappers/`. Zig was chosen over musl.cc / gcc
  cross prebuilts because aarch64-hosted versions of those aren't
  published.
- **Rust linker** is **not** set explicitly. `cargo-zigbuild` installs
  its own linker wrapper that strips Rust's self-contained musl crt
  files (which would otherwise collide with Zig's musl crt). Setting
  `CARGO_TARGET_*_LINKER` ourselves overrides that and produces
  duplicate-symbol link errors.
- **`pkg-config`** points at `/opt/cross-x86_64-musl/lib/pkgconfig` for
  the musl stages; the virtiofsd block overrides it in a subshell to
  point at `/opt/cross-x86_64-gnu/lib/pkgconfig` so `libseccomp-sys`
  and `libcap-ng`'s `capng-sys` resolve against the glibc-dynamic
  `.so` files, not the static-musl `.a` archives. The musl prefix uses
  GNU ld linker scripts at `lib{seccomp,cap-ng}.so` to redirect
  dynamic-link requests into the static archives; the gnu prefix ships
  real shared libraries.

The cross C dep prefixes are built by `scripts/build-musl-x86_64-deps.sh`
and `scripts/build-glibc-x86_64-deps.sh` during `make linux-image`.
Modifying either script invalidates that layer of the dev image and
triggers a rebuild on the next `make dist-x86_64`.

## Troubleshooting

- **`ERROR: missing .local/cloud-hypervisor source checkout`** — see
  Prerequisites. There is no fetch target; clone the revision you want
  pinned.
- **`ERROR: no x86_64 kernel found`** — run
  `make -C kernel TARGET_ARCH=x86_64`. The build refuses to ship a
  tarball without a kernel.
- **`ERROR: virtiofsd cap-drop patch does not apply cleanly`** — the
  patch only applies to known-good upstream revisions of virtiofsd. If
  you bumped `.local/virtiofsd` past that, refresh
  `scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch`
  against the new revision.
- **Stale binary on the deployment host** — confirm the tarball SHA in
  `bin/containerization-x86_64-<sha>.tar.gz` matches `git rev-parse
  --short HEAD`. The script tags the tarball with `HEAD` at build time;
  uncommitted changes ship under the same SHA as their parent commit.
- **Linker errors mentioning duplicate `crt*.o` symbols** — something is
  setting `CARGO_TARGET_*_LINKER`. Unset it and let `cargo-zigbuild`
  manage the linker.
- **`virtiofsd: error while loading shared libraries: libseccomp.so.2`**
  (or `libcap-ng.so.0`) on the deployment host — install the system
  packages (`apt install libseccomp2 libcap-ng0` on Debian/Ubuntu,
  `dnf install libseccomp libcap-ng` on Fedora/RHEL). `virtiofsd` is
  glibc-dynamic by design; the libs are not bundled in the tarball.
- **`virtiofsd: /lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.35'
  not found`** — the deployment host's glibc is older than the build's
  baseline. Either upgrade the host or rebuild with a lower baseline
  by editing the `-target x86_64-linux-gnu.<ver>` arg in
  `images/linux-dev/wrappers/x86_64-linux-gnu-{gcc,g++}` and the
  `cargo zigbuild --target x86_64-unknown-linux-gnu.<ver>` line in
  `scripts/build-dist-x86_64.sh`.
