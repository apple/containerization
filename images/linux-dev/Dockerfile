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

ARG SWIFT_VERSION=6.3
FROM swift:${SWIFT_VERSION}-noble

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        make \
        libarchive-dev \
        libbz2-dev \
        liblzma-dev \
        libssl-dev \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

ARG SWIFT_SDK_URL
ARG SWIFT_SDK_CHECKSUM
RUN if [ -n "$SWIFT_SDK_URL" ]; then \
      swift sdk install "$SWIFT_SDK_URL" --checksum "$SWIFT_SDK_CHECKSUM"; \
    fi

# x86_64 cross-build tooling
# ---
# Used by `make dist-x86_64` to produce a Linux x86_64 deployment
# tarball from this aarch64 dev container. Adds: Zig (used as a
# clang-based cross C/C++ compiler — its bundled musl + LLVM lets us
# target x86_64-linux-musl from any host arch), wrapper scripts that
# look like a standard `x86_64-linux-musl-*` toolchain so autotools'
# `--host=x86_64-linux-musl` works, parallel `x86_64-linux-gnu-*`
# wrappers pinned at glibc 2.35 for virtiofsd's dynamic build,
# Rust stable + both x86_64-unknown-linux-{musl,gnu} targets,
# autotools/gperf, static-musl builds of zlib, xz, bzip2, libarchive,
# libcap-ng, and libseccomp at /opt/cross-x86_64-musl, and
# glibc-dynamic builds of libcap-ng and libseccomp at
# /opt/cross-x86_64-gnu.

# Build deps for static-musl C libraries.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        libtool \
        gperf \
        curl \
        ca-certificates \
        xz-utils \
        build-essential \
        pkg-config \
        lld \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Zig (cross compiler). Pin to a specific release; bump as needed.
# Zig provides clang-based `zig cc -target ...` plus `zig ar`, `zig
# ranlib`, etc., bundled with musl libc — no need for a separate
# arch-specific gcc cross toolchain.
#
# The SHA256 is captured from the upstream release index
# (https://ziglang.org/download/) and verified before extraction so a
# tampered tarball can't poison the dev image.
ARG ZIG_VERSION=0.13.0
ARG ZIG_AARCH64_SHA256=041ac42323837eb5624068acd8b00cd5777dac4cf91179e8dad7a7e90dd0c556
RUN set -eux; \
    curl -fsSL -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-aarch64-${ZIG_VERSION}.tar.xz"; \
    echo "${ZIG_AARCH64_SHA256}  /tmp/zig.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    rm /tmp/zig.tar.xz; \
    ln -s "/opt/zig-linux-aarch64-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

# Wrapper scripts that look like conventional cross toolchains —
# `x86_64-linux-musl-{gcc,g++,cc,c++,ar,ranlib,strip}` for the musl
# side (used by cctl, vminitd, cloud-hypervisor) and parallel
# `x86_64-linux-gnu-*` wrappers for virtiofsd's glibc-dynamic build.
# All dispatch to zig under the hood. Lets autotools'
# `--host=x86_64-linux-{musl,gnu}` and cargo's
# CARGO_TARGET_X86_64_UNKNOWN_LINUX_{MUSL,GNU}_LINKER point at these
# names without knowing about Zig.
#
# The C/C++ wrappers filter out `--target=<triple>` args that cc-rs
# (used by Rust build scripts like zstd-sys, libseccomp-sys) adds —
# cc-rs emits the Rust-form triple (e.g. x86_64-unknown-linux-musl)
# which Zig refuses to parse, and we always set our own -target.
COPY images/linux-dev/wrappers/ /usr/local/bin/
RUN chmod +x /usr/local/bin/x86_64-linux-musl-* \
 && ln -s x86_64-linux-musl-gcc /usr/local/bin/x86_64-linux-musl-cc \
 && ln -s x86_64-linux-musl-g++ /usr/local/bin/x86_64-linux-musl-c++ \
 && chmod +x /usr/local/bin/x86_64-linux-gnu-* \
 && ln -s x86_64-linux-gnu-gcc /usr/local/bin/x86_64-linux-gnu-cc \
 && ln -s x86_64-linux-gnu-g++ /usr/local/bin/x86_64-linux-gnu-c++

# Rust toolchain at the same path the existing build-cloud-hypervisor /
# build-virtiofsd targets expect, with the x86_64-musl cross target
# pre-installed so dist-x86_64 doesn't redo it on every run. Also
# installs cargo-zigbuild — a cargo subcommand that uses Zig as the
# linker and handles the Rust+musl+Zig integration (specifically: it
# strips Rust's self-contained musl crt files so they don't collide
# with Zig's, and wires up libunwind correctly).
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal \
 && /root/.cargo/bin/rustup target add x86_64-unknown-linux-musl \
 && /root/.cargo/bin/rustup target add x86_64-unknown-linux-gnu \
 && /root/.cargo/bin/cargo install --locked cargo-zigbuild
ENV PATH="/root/.cargo/bin:${PATH}"

# Static-musl C libraries (libarchive + deps for cctl, libcap-ng +
# libseccomp for virtiofsd). Installs to /opt/cross-x86_64-musl;
# build-dist-x86_64.sh adds -L/-I flags pointing at that prefix when
# linking the host-side binaries.
COPY scripts/build-musl-x86_64-deps.sh /tmp/build-musl-x86_64-deps.sh
RUN /tmp/build-musl-x86_64-deps.sh && rm /tmp/build-musl-x86_64-deps.sh

# Glibc-dynamic C libraries for virtiofsd. virtiofsd ships
# glibc-dynamic in the x86_64 tarball so deployment hosts use their
# system libseccomp.so.2 + libcap-ng.so.0; this prefix only provides
# the link-time .so + headers + pkg-config files. cloud-hypervisor
# and cctl stay musl-static and link against /opt/cross-x86_64-musl/.
COPY scripts/build-glibc-x86_64-deps.sh /tmp/build-glibc-x86_64-deps.sh
RUN /tmp/build-glibc-x86_64-deps.sh && rm /tmp/build-glibc-x86_64-deps.sh
