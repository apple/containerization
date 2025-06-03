FROM ubuntu:focal

RUN apt-get update && apt-get install -y \
    autoconf \
    bc \
    binutils-multiarch \
    binutils-aarch64-linux-gnu \
    binutils-x86-64-linux-gnu \
    bison \
    flex \
    gcc \
    gcc-aarch64-linux-gnu \
    gcc-x86-64-linux-gnu \
    git \
    libncurses-dev \
    make \
    openssl \
    python-is-python3 \
&&  apt-get clean \
&&  rm -rf /var/lib/apt/lists/*

COPY sources.list /etc/apt/sources.list

RUN apt-get update \
&&  dpkg --add-architecture amd64 \
&&  dpkg --add-architecture arm64 \
&&  apt-get install -y libelf-dev:amd64 libelf-dev:arm64 \
&&  apt-get clean \
&&  rm -rf /var/lib/apt/lists/*