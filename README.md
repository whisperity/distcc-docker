[DistCC](http://distcc.org) Docker (LTS)
========================================

This project provides support for executing a [DistCC](http://distcc.org) worker in a [Docker](http://docker.com) environment, supporting all major compilers' every accessible LTS-available version on the platform.
Put simply, this allows using a single DistCC environment, using, e.g., an Ubuntu 20.04 base image, to run the major compilers available under Ubuntu 20.04, 22.04, and 24.04 LTSes simultaneously.


Usage
-----


### Downloading or building the image

You can build the image yourself locally:

```bash
docker build \
  --tag distcc-service:latest \
  .
```

By default, the building of the image will install the necessary and available compiler versions for best support.
In case a smaller image is deemed necessary, pass `--build-arg="LAZY_COMPILERS=1"`.
The resulting image will install the curated list of compilers **at the first start** of the container, without occupying space in the _image_.
However, this will increase the network use and the initial deployment time of the containers.


### Setting up the workers

You can start the container manually, with the following arguments.
The running container will act as the master DistCC daemon of the host computer, listening on the _default_ ports `3632` and `3633`.

```bash
docker run  \
  --detach  \
  --init \
  --publish 3632:3632/tcp \
  --publish 3633:3633/tcp \
  --restart unless-stopped \
  --mount type=tmpfs,destination=/tmp,tmpfs-mode=1770,tmpfs-size=8G \
  <IMAGE NAME???>
```

The number of worker threads available for the service can be configured by passing `--jobs N` after the image name, directly to the container's _"`main()`"_ script.
The suggested _default_ is the number of CPU threads available on the machine, minus 2.
