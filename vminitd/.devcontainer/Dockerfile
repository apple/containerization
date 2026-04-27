ARG SWIFT_VERSION=6.3
FROM swift:${SWIFT_VERSION}-noble

RUN apt-get update \
&&  apt-get install make \
&&  apt-get clean \
&&  rm -rf /var/lib/apt/lists/*
RUN swift sdk install \
    https://download.swift.org/swift-6.3-branch/static-sdk/swift-6.3-DEVELOPMENT-SNAPSHOT-2026-03-05-a/swift-6.3-DEVELOPMENT-SNAPSHOT-2026-03-05-a_static-linux-0.1.0.artifactbundle.tar.gz \
    --checksum f19419ad6a90d0fe5bbf8a28fbc47217ce212633c28257fc6549162558e6f9b6
