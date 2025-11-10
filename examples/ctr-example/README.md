# Container Example

Very basic example of launching a Linux container using Containerization.

## Build and Run

### 1. Fetch Kernel

In your terminal, change directories to examples/ctr-example and run
`make fetch-default-kernel`

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

**Congratulations, you've started the example container!**
