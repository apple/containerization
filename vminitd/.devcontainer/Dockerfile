FROM swift:6.2

RUN apt-get update \
&&  apt-get install make \
&&  apt-get clean \
&&  rm -rf /var/lib/apt/lists/*
RUN swift sdk install https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz --checksum f30ec724d824ef43b5546e02ca06a8682dafab4b26a99fbb0e858c347e507a2c
