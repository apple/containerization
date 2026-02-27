# Container Example

Very basic example of launching a Linux container using Containerization.

## Build and Run

### 0. Verify Your Setup

Before building, ensure you have the required dependencies:

- **macOS**: macOS 26.0 or later (preferably the latest available release)
- **Xcode**: Xcode 26.0 or later (preferably the latest available release)
- **Swift**: Apple Swift version 6.2 or later
- **Hardware**: Mac with Apple silicon

You can verify your Swift version by running:
```bash
swift --version
```

### 1. Fetch Kernel

In your terminal, change directories to examples/ctr-example and run:

**Option A: Using Makefile (recommended)**
```bash
make fetch-default-kernel
```

**Option B: Copy from installed container tool**
```bash
cp "$(ls -t ~/Library/Application\ Support/com.apple.container/kernels/vmlinux-* | head -1)" ./vmlinux
```

You should now see the `vmlinux` image in examples/ctr-example

### 2. Build/Run ctr-example

From examples/ctr-example run
`make all`

> [!WARNING]
> If you get the following error, try building from the default macOS terminal:
> `error: compiled module was created by a newer version of the compiler`

After the build completes, the example will run. In your terminal you should see something like:

```
Starting container example...
Fetching container initial filesystem...
Creating container from docker.io/library/alpine:3.16...
Starting container...
/ #
```

> [!WARNING]
> If you get the following error, try moving the `ctr-example` binary to `/var/tmp` and run it from there.
> `Swift/ErrorType.swift:254: Fatal error: Error raised at top level: unsupported: "failed to create vmnet network with status vmnet_return_t(rawValue: 1001)"`

**Congratulations, you've started the example container!**
