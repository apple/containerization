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

# Builds x86_64-linux-gnu shared-library versions of libseccomp and
# libcap-ng (the two C libs virtiofsd links against) and installs them
# at /opt/cross-x86_64-gnu. Sibling of build-musl-x86_64-deps.sh; the
# Dockerfile invokes both at image build time.
#
# Why a separate prefix: virtiofsd ships glibc-dynamic in the x86_64
# tarball (see docs/x86_64-build.md) so deployment hosts can use their
# system libseccomp.so.2 + libcap-ng.so.0; everything else in the tarball
# stays musl-static. Mixing static-musl .a archives and dynamic-gnu .so
# files at one prefix confuses pkg-config and the linker, so they live
# apart.
#
# The glibc baseline is pinned at 2.35 (Ubuntu 22.04 / Debian 12 / RHEL 9
# era) via the Zig wrapper scripts at /usr/local/bin/x86_64-linux-gnu-*,
# which dispatch to `zig cc -target x86_64-linux-gnu.2.35`. Bump the
# wrapper triple if the baseline moves.
#
# Only two libraries here, both shared: virtiofsd's other build-script
# deps (zstd, etc.) come from cargo crates that vendor C sources, and
# cctl's libarchive lives on the musl side.

set -euo pipefail

HOST=x86_64-linux-gnu
PREFIX=/opt/cross-x86_64-gnu

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

# Sanity check: cross compiler produces clean output for a trivial
# program. autotools / libtool turn unexpected compiler chatter into
# baffling configure errors; surfacing it here gives a real message.
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
fi

# libcap-ng — github auto-archive (release artifacts for older tags
# aren't always uploaded).
LIBCAP_NG_VERSION=0.8.5
fetch_extract "https://github.com/stevegrubb/libcap-ng/archive/refs/tags/v${LIBCAP_NG_VERSION}.tar.gz" libcap-ng.tar.gz
(
    cd "libcap-ng-${LIBCAP_NG_VERSION}"
    # GNU automake's strict mode requires these standard files to exist;
    # the auto-archive tarball doesn't ship NEWS. Cheaper than
    # configure.ac surgery.
    touch NEWS README AUTHORS ChangeLog
    autoreconf -i
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        --disable-static --enable-shared \
        --without-python --without-python3
    make -j"${JOBS}"
    make install
)

# libseccomp — needs gperf at build time (installed via the Dockerfile
# alongside the musl deps). Built shared here.
LIBSECCOMP_VERSION=2.5.5
fetch_extract "https://github.com/seccomp/libseccomp/releases/download/v${LIBSECCOMP_VERSION}/libseccomp-${LIBSECCOMP_VERSION}.tar.gz" libseccomp.tar.gz
(
    cd "libseccomp-${LIBSECCOMP_VERSION}"
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        --disable-static --enable-shared \
        --disable-python
    make -j"${JOBS}"
    make install
)

# Drop libtool .la files — they encode build-host paths and confuse
# downstream consumers; the .so + pkg-config .pc files are sufficient.
rm -f "${PREFIX}/lib"/*.la

# Force the unversioned dev symlinks (libseccomp.so, libcap-ng.so).
# libtool conservatively omits these when cross-compiling, but rustc's
# link step looks for them by unversioned name; without them the
# link fails with "unable to find dynamic system library 'seccomp'".
# Idempotent — `ln -sf` overwrites any existing symlink, and the loop
# picks up whatever versioned files libtool actually installed.
for stem in libseccomp libcap-ng; do
    versioned=$(ls "${PREFIX}/lib/${stem}.so."* 2>/dev/null | sort -V | head -n1)
    if [ -n "${versioned}" ]; then
        ln -sf "$(basename "${versioned}")" "${PREFIX}/lib/${stem}.so"
    else
        echo "ERROR: no ${stem}.so.* found in ${PREFIX}/lib after install" >&2
        ls -la "${PREFIX}/lib" >&2
        exit 1
    fi
done

echo "glibc-dynamic x86_64 C deps installed under ${PREFIX}"
