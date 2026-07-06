#!/bin/bash
# Copyright © 2026 Apple Inc. and the Containerization project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Builds the x86_64 deployment tarball.
#
# Runs INSIDE the aarch64 Linux dev container (invoked by
# `make dist-x86_64` via the linux_run macro). Cross-compiles all four
# host-side binaries — cctl, vminitd, cloud-hypervisor, virtiofsd —
# to x86_64-linux-musl, packs an initfs.ext4 with the x86_64 guest
# binaries inside, and emits bin/containerization-x86_64-<sha>.tar.gz.
#
# See docs/x86_64-build.md for full documentation: prerequisites,
# pipeline stages, toolchain rationale, and troubleshooting.
#
# Force-rebuild env vars (default = skip stages whose outputs are
# up-to-date):
#   REBUILD_VMINITD=1     vminitd + vmexec
#   REBUILD_INITFS=1      initfs.ext4 (and the native aarch64 cctl packer)
#   REBUILD_CH=1          cloud-hypervisor
#   REBUILD_VIRTIOFSD=1   virtiofsd
# cctl x86 cross always rebuilds (Swift incremental handles no-ops).

set -euo pipefail

cd /workspace

GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
DIST_NAME="containerization-x86_64-${GIT_SHA}"
DIST_DIR="bin/dist-x86_64"
STAGE="${DIST_DIR}/${DIST_NAME}"
TGZ="bin/${DIST_NAME}.tar.gz"

CROSS_PREFIX=/opt/cross-x86_64-musl
GNU_PREFIX=/opt/cross-x86_64-gnu
PATCH=/workspace/scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch

# Cargo cross env for the musl stages (cctl, vminitd, cloud-hypervisor).
# CC/CXX/AR are used by cc-rs (Rust build scripts that compile C, e.g.
# zstd-sys, libseccomp-sys, capng) — points them at the Zig-backed
# wrappers. Linker is intentionally NOT set here: cargo-zigbuild
# installs its own linker wrapper that strips Rust's self-contained
# musl crt files (which would otherwise collide with Zig's musl crt).
# Setting CARGO_TARGET_*_LINKER ourselves would override that and
# cause duplicate-symbol link errors.
# pkg-config (used by libseccomp-sys and libcap-ng's capng-sys) points
# at the static-musl prefix, not the aarch64 host.
# PKG_CONFIG_ALL_STATIC=1 makes pkg-config-rs emit
# `rustc-link-lib=static=...` for resolved libs — required because
# the C libs at $CROSS_PREFIX are static-only (.a, no .so), so the
# default dynamic link would fail to find the .so.
#
# virtiofsd has its own glibc-dynamic env block below; it overrides
# PKG_CONFIG_LIBDIR / SYSROOT_DIR in a subshell so the musl values
# stay correct for cloud-hypervisor.
. /root/.cargo/env
export CC_x86_64_unknown_linux_musl=x86_64-linux-musl-gcc
export CXX_x86_64_unknown_linux_musl=x86_64-linux-musl-g++
export AR_x86_64_unknown_linux_musl=x86_64-linux-musl-ar
export PKG_CONFIG_LIBDIR="${CROSS_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${CROSS_PREFIX}"
export PKG_CONFIG_ALLOW_CROSS=1
# Add the static-musl cross prefix to rustc's native library search
# path so the linker finds the libseccomp.so / libcap-ng.so linker
# scripts that build-musl-x86_64-deps.sh installs alongside the .a
# files. The scripts redirect resolution to the static archives.
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-L native=${CROSS_PREFIX}/lib"

# Pre-flight checks
[ -f .local/cloud-hypervisor/Cargo.toml ] || {
    echo "ERROR: missing .local/cloud-hypervisor source checkout." >&2
    echo "  git clone -b v52.0 https://github.com/cloud-hypervisor/cloud-hypervisor .local/cloud-hypervisor" >&2
    exit 1
}
[ -f .local/virtiofsd/Cargo.toml ] || {
    echo "ERROR: missing .local/virtiofsd source checkout." >&2
    echo "  git clone https://gitlab.com/virtio-fs/virtiofsd .local/virtiofsd" >&2
    exit 1
}

# Kernel candidates (prefer the compressed bzImage produced by
# `make -C kernel TARGET_ARCH=x86_64`, fall back to an uncompressed
# vmlinux). The kernel is required — a tarball without one isn't
# usable, so fail hard rather than silently producing one.
KERNEL_SRC=
for candidate in kernel/vmlinuz-x86_64 kernel/vmlinux-x86_64; do
    if [ -f "$candidate" ]; then
        if file "$candidate" | grep -qE 'x86 boot|x86-64'; then
            KERNEL_SRC=$candidate
            break
        else
            echo "ERROR: $candidate exists but is not x86_64." >&2
            file "$candidate" >&2
            exit 1
        fi
    fi
done
if [ -z "${KERNEL_SRC}" ]; then
    echo "ERROR: no x86_64 kernel found at kernel/vmlinuz-x86_64 or kernel/vmlinux-x86_64." >&2
    echo "       build one with 'make -C kernel TARGET_ARCH=x86_64'." >&2
    exit 1
fi

mkdir -p "${DIST_DIR}"

# Decide which steps need to run before doing any work, so log messages
# match what's actually happening.

NEED_VMINITD=1
if [ "${REBUILD_VMINITD:-0}" != "1" ] \
    && [ -x "${DIST_DIR}/vminitd" ] && [ -x "${DIST_DIR}/vmexec" ] \
    && [ -z "$(find vminitd/Sources vminitd/Package.swift Sources/Containerization/SandboxContext \
        -newer "${DIST_DIR}/vminitd" -print -quit 2>/dev/null)" ] \
    && [ -z "$(find vminitd/Sources vminitd/Package.swift Sources/Containerization/SandboxContext \
        -newer "${DIST_DIR}/vmexec" -print -quit 2>/dev/null)" ]; then
    NEED_VMINITD=0
fi

NEED_INITFS=1
if [ "${REBUILD_INITFS:-0}" != "1" ] \
    && [ "${NEED_VMINITD}" = "0" ] \
    && [ -f "${DIST_DIR}/initfs.ext4" ] \
    && [ "${DIST_DIR}/initfs.ext4" -nt "${DIST_DIR}/vminitd" ] \
    && [ "${DIST_DIR}/initfs.ext4" -nt "${DIST_DIR}/vmexec" ]; then
    NEED_INITFS=0
fi

NEED_CH=1
if [ "${REBUILD_CH:-0}" != "1" ] && [ -x "${DIST_DIR}/cloud-hypervisor" ]; then
    NEED_CH=0
fi

NEED_VIRTIOFSD=1
if [ "${REBUILD_VIRTIOFSD:-0}" != "1" ] && [ -x "${DIST_DIR}/virtiofsd" ]; then
    NEED_VIRTIOFSD=0
fi

echo "==> Cross-compiling cctl to x86_64-linux-musl"
swift build -c release \
    --swift-sdk x86_64-swift-linux-musl \
    --product cctl \
    -Xswiftc -warnings-as-errors \
    -Xlinker -L"${CROSS_PREFIX}/lib" \
    --disable-automatic-resolution
CCTL_X86_64_BIN="$(swift build -c release --swift-sdk x86_64-swift-linux-musl --show-bin-path)/cctl"
install -m 755 "${CCTL_X86_64_BIN}" "${DIST_DIR}/cctl"

if [ "${NEED_VMINITD}" = "1" ]; then
    echo "==> Cross-compiling vminitd + vmexec to x86_64-linux-musl"
    make -C vminitd \
        LIBC=musl \
        MUSL_ARCH=x86_64 \
        BUILD_CONFIGURATION=release \
        INSTALL_DIR="$(pwd)/${DIST_DIR}"
else
    echo "==> Reusing staged vminitd + vmexec (sources unchanged; set REBUILD_VMINITD=1 to force)"
fi

if [ "${NEED_CH}" = "1" ]; then
    echo "==> Cross-compiling cloud-hypervisor to x86_64-unknown-linux-musl"
    (
        cd .local/cloud-hypervisor
        cargo zigbuild --release --target x86_64-unknown-linux-musl --bin cloud-hypervisor
    )
    install -m 755 \
        ".local/cloud-hypervisor/target/x86_64-unknown-linux-musl/release/cloud-hypervisor" \
        "${DIST_DIR}/cloud-hypervisor"
else
    echo "==> Reusing staged cloud-hypervisor (set REBUILD_CH=1 to force)"
fi

if [ "${NEED_VIRTIOFSD}" = "1" ]; then
    echo "==> Cross-compiling virtiofsd to x86_64-unknown-linux-gnu.2.35 (glibc-dynamic, with cap-drop patch)"
    # virtiofsd ships glibc-dynamic: the deployment host provides
    # libseccomp.so.2 and libcap-ng.so.0 at runtime. Subshell scopes
    # the gnu env so it doesn't bleed into other stages.
    (
        export CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc
        export CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++
        export AR_x86_64_unknown_linux_gnu=x86_64-linux-gnu-ar
        export PKG_CONFIG_LIBDIR="${GNU_PREFIX}/lib/pkgconfig"
        export PKG_CONFIG_SYSROOT_DIR="${GNU_PREFIX}"
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-L native=${GNU_PREFIX}/lib"
        cd .local/virtiofsd
        if git apply --check "${PATCH}" 2>/dev/null; then
            git apply "${PATCH}"
            echo "applied virtiofsd cap-drop patch"
        elif git apply --reverse --check "${PATCH}" 2>/dev/null; then
            echo "virtiofsd cap-drop patch already applied"
        else
            echo "ERROR: virtiofsd cap-drop patch does not apply cleanly" >&2
            exit 1
        fi
        cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.35
    )
    install -m 755 \
        ".local/virtiofsd/target/x86_64-unknown-linux-gnu/release/virtiofsd" \
        "${DIST_DIR}/virtiofsd"
else
    echo "==> Reusing staged virtiofsd (set REBUILD_VIRTIOFSD=1 to force)"
fi

if [ "${NEED_INITFS}" = "1" ]; then
    echo "==> Building aarch64 cctl natively (used to pack initfs.ext4)"
    swift build -c release --product cctl -Xswiftc -warnings-as-errors --disable-automatic-resolution
    NATIVE_CCTL="$(swift build -c release --show-bin-path)/cctl"

    echo "==> Building initfs.ext4 with x86_64 guest binaries"
    rm -f "${DIST_DIR}/init.rootfs.tar.gz" "${DIST_DIR}/initfs.ext4"
    "${NATIVE_CCTL}" rootfs create \
        --vminitd "${DIST_DIR}/vminitd" \
        --vmexec "${DIST_DIR}/vmexec" \
        --ext4 "${DIST_DIR}/initfs.ext4" \
        --label org.opencontainers.image.source=https://github.com/apple/containerization \
        --image vminit-x86_64:latest \
        "${DIST_DIR}/init.rootfs.tar.gz"
else
    echo "==> Reusing staged initfs.ext4 (vminitd/vmexec unchanged; set REBUILD_INITFS=1 to force)"
fi

echo "==> Staging tree at ${STAGE} and packaging"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin"
install -m 755 "${DIST_DIR}/cctl" "${STAGE}/bin/cctl"
install -m 755 "${DIST_DIR}/cloud-hypervisor" "${STAGE}/bin/cloud-hypervisor"
install -m 755 "${DIST_DIR}/virtiofsd" "${STAGE}/bin/virtiofsd"
mkdir -p "${STAGE}/kernel"
cp "${KERNEL_SRC}" "${STAGE}/kernel/$(basename "${KERNEL_SRC}")"
cp "${DIST_DIR}/initfs.ext4" "${STAGE}/initfs.ext4"
rm -f "${TGZ}"
tar -czf "${TGZ}" -C "${DIST_DIR}" "${DIST_NAME}"
echo "wrote ${TGZ}"
