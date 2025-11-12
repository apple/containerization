#

## Install and test the container tool:

See https://github.com/apple/container/releases

Once installed, start the service and follow prompts.

```bash
container system start
```

This'll install your kernel.

After this start your first container. On first launch, this'll install another artifact for our guest init process:

```
container run -it alpine sh
```

Container starts after this will be fast!

## Get the Containerization sources:

```bash
$ git clone https://github.com/apple/containerization.git
```

> [!IMPORTANT]
> There is a bug in the `vmnet` framework on macOS 26 that causes network creation to fail if the creating applications are located under your `Documents` or `Desktop` directories. To workaround this, clone the project elsewhere, such as `~/projects/containerization`, until this issue is resolved.

## Take a look at ctr-example

Read through the sources:

- ContainerManager:
- manager.create()
- container.create(), start(), wait(), stop()

## Fetch the kernel

Run 

```bash
cp "$(ls -t ~/Library/Application\ Support/com.apple.container/kernels/vmlinux-* | head -1)" ./vmlinux
```

## Build and run the example

```bash
$ cd examples/ctr-example
$ make
```

## Modify the project

- Change the command run by the container
- Change the image
