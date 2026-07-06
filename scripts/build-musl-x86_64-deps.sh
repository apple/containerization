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

# Builds static-musl x86_64 versions of the C libraries that cctl and
# virtiofsd link against, and installs them at /opt/cross-x86_64-musl
# (a standalone prefix — the Zig-based cross compiler has no
# traditional sysroot, so the build-dist-x86_64.sh script and the
# cargo cross flow add explicit -L / -I flags pointing here).
#
# Invoked once at dev-image build time; the resulting layer is cached
# until this script changes. Adding/removing a library here is the only
# reason to invalidate it.

set -euo pipefail

HOST=x86_64-linux-musl
PREFIX=/opt/cross-x86_64-musl

mkdir -p "${PREFIX}/lib" "${PREFIX}/include"

export CC="${HOST}-gcc"
export CXX="${HOST}-g++"
export AR="${HOST}-ar"
export RANLIB="${HOST}-ranlib"
export STRIP="${HOST}-strip"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}"

JOBS="$(nproc)"

# fetch_extract URL ARCHIVE
#
# Downloads URL to ARCHIVE then extracts. Relies on HTTPS for transport
# integrity; no SHA pinning. The other build-time deps (apt packages,
# Zig, Rust toolchain) trust the same.
fetch_extract() {
    local url=$1 archive=$2
    curl -fsSL -o "${archive}" "${url}"
    tar -xf "${archive}"
}

# Sanity check: cross compiler is on PATH and produces clean output
# for a trivial program. If it doesn't, zlib's configure script (which
# treats any stderr/stdout from a test compile as evidence of -Werror)
# will fail with a misleading "Compiler error reporting is too harsh"
# error. Surfacing this here gives us a real error message instead.
echo "==> cross compiler sanity check"
"${CC}" --version
cat > "${WORK}/sanity.c" <<'EOF'
void foo(void) {}
EOF
out=$("${CC}" -c "${WORK}/sanity.c" -o "${WORK}/sanity.o" 2>&1) || {
    echo "ERROR: cross compiler failed on trivial test.c:" >&2
    echo "${out}" >&2
    exit 1
}
if [ -n "${out}" ]; then
    echo "WARNING: cross compiler emitted output on a clean compile:" >&2
    echo "${out}" >&2
    echo "(this will trip up zlib's configure script — see fix below)" >&2
fi

# zlib — provides libz.a. Its configure does not take --host, so the
# CC env var is what selects the cross compiler.
ZLIB_VERSION=1.3.1
fetch_extract "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" zlib.tar.gz
(
    cd "zlib-${ZLIB_VERSION}"
    if ! ./configure --static --prefix="${PREFIX}"; then
        echo "==================== zlib configure.log ====================" >&2
        [ -f configure.log ] && cat configure.log >&2
        echo "============================================================" >&2
        exit 1
    fi
    make -j"${JOBS}"
    make install
)

# xz — provides liblzma.a.
XZ_VERSION=5.6.4
fetch_extract "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" xz.tar.gz
(
    cd "xz-${XZ_VERSION}"
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --disable-doc --disable-scripts \
        --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
        --disable-lzma-links
    make -j"${JOBS}"
    make install
)

# bzip2 — no autotools, drives a plain Makefile. Build only the static
# library; the bzip2 CLI tools are not needed.
BZIP2_VERSION=1.0.8
fetch_extract "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz" bzip2.tar.gz
(
    cd "bzip2-${BZIP2_VERSION}"
    make CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" libbz2.a -j"${JOBS}"
    install -m 644 libbz2.a "${PREFIX}/lib/"
    install -m 644 bzlib.h "${PREFIX}/include/"
)

# libarchive — needs zlib + lzma + bz2 (built above). Disable optional
# deps that pull in extra toolchain weight (xml2, iconv, zstd, lz4,
# openssl, libb2). cctl uses libarchive for tar/ext layouts; the
# disabled formats are not used at runtime.
LIBARCHIVE_VERSION=3.7.7
fetch_extract "https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VERSION}/libarchive-${LIBARCHIVE_VERSION}.tar.gz" libarchive.tar.gz
(
    cd "libarchive-${LIBARCHIVE_VERSION}"
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --disable-bsdtar --disable-bsdcat --disable-bsdcpio --disable-bsdunzip \
        --without-xml2 --without-iconv --without-zstd --without-lz4 \
        --without-openssl --without-libb2 \
        CPPFLAGS="-I${PREFIX}/include" \
        LDFLAGS="-L${PREFIX}/lib"
    make -j"${JOBS}"
    make install
)

# libcap-ng — github auto-archive (release artifacts for older tags
# aren't always uploaded; the auto-archive URL is always available
# for any tag, but doesn't ship a pre-generated configure script, so
# we autoreconf it ourselves).
LIBCAP_NG_VERSION=0.8.5
fetch_extract "https://github.com/stevegrubb/libcap-ng/archive/refs/tags/v${LIBCAP_NG_VERSION}.tar.gz" libcap-ng.tar.gz
(
    cd "libcap-ng-${LIBCAP_NG_VERSION}"
    # GNU automake's default (strict) mode requires these standard
    # files to exist; the auto-archive tarball doesn't ship NEWS.
    # Cheaper than configure.ac surgery.
    touch NEWS README AUTHORS ChangeLog
    autoreconf -i
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --without-python --without-python3
    make -j"${JOBS}"
    make install
)

# libseccomp — needs gperf at build time (installed via apt above).
LIBSECCOMP_VERSION=2.5.5
fetch_extract "https://github.com/seccomp/libseccomp/releases/download/v${LIBSECCOMP_VERSION}/libseccomp-${LIBSECCOMP_VERSION}.tar.gz" libseccomp.tar.gz
(
    cd "libseccomp-${LIBSECCOMP_VERSION}"
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        --enable-static --disable-shared \
        --disable-python
    make -j"${JOBS}"
    make install
)

# Linker-script `.so` shims for libseccomp + libcap-ng. The Rust
# `-sys` crates emit plain `cargo:rustc-link-lib=seccomp` (no
# static= prefix), and they don't declare `links = "..."` in their
# Cargo.toml, so cargo's build-script override can't match them.
# Instead we hand the linker fake `.so` files that are actually GNU
# ld linker scripts pointing at the static archive — when ld resolves
# `-lseccomp` to libseccomp.so it reads the script and pulls in
# libseccomp.a as if statically linked. Works regardless of -Bstatic
# vs -Bdynamic state and avoids needing to patch the -sys crates.
cat > "${PREFIX}/lib/libseccomp.so" <<EOF
/* Linker script: pull in the static archive when -lseccomp resolves here. */
GROUP ( ${PREFIX}/lib/libseccomp.a )
EOF
cat > "${PREFIX}/lib/libcap-ng.so" <<EOF
/* Linker script: pull in the static archive when -lcap-ng resolves here. */
GROUP ( ${PREFIX}/lib/libcap-ng.a )
EOF

echo "static-musl x86_64 C deps installed under ${PREFIX}"
