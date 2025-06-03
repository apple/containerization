FROM ghcr.io/apple/backpack-test/kernel-build:latest as build
COPY . /src
WORKDIR /src
RUN make prepare-kernel
RUN make build-kernel

FROM scratch
LABEL org.opencontainers.image.source=https://github.com/apple/containerization
COPY --from=build /src/kernel.arm64 /
