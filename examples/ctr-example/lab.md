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
$ git clone git@github.com:apple/containerization.git
```

## Take a look at ctr-example

Read through the sources:

- ContainerManager: 
- manager.create()
- container.create(), start(), wait(), stop()

## Build and run the example

```bash
$ cd examples/ctr-example
$ make
$ ./ctr-example
```
## Modify the project

- Change the command run by the container
- Change the image

