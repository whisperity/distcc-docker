[DistCC](http://distcc.org) Docker
==================================

This project provides support for executing a [DistCC](http://distcc.org) worker in a [Docker](http://docker.com) environment, supporting all major compilers' every accessible LTS-available version on the platform.
Put simply, this allows using a single DistCC environment, using, e.g., an Ubuntu 20.04 base image, to run the major compilers available under Ubuntu 20.04, 22.04, and 24.04 LTSes simultaneously.



Usage
-----

The easiest way to obtain a running container with the default and suggested configuration is by calling `docker compose up` for the provided [`docker-compose.yml`](/docker-compose.yml) file.


```bash
docker-compose up --detach
```

> [!IMPORTANT]
>
> For **Ubuntu 20.04 "Focal Fossa" LTS** host computers, it is very likely that a newer version of _Docker Compose_ is needed first:
>
>
> ```bash
> wget "http://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64"
> sudo mv "./docker-compose-linux-x86_64" "/usr/local/bin/docker-compose"
> sudo chmod +x "/usr/local/bin/docker-compose"
> ```



### Downloading or building the image

The image is available in the [**GitHub Container Registry**](http://ghcr.io) under [`whisperity/distcc-docker`](http://github.com/whisperity/distcc-docker/pkgs/container/distcc-docker).

Alternatively, you can build the image yourself locally after cloning the repository:


```bash
docker build \
  --tag distcc-docker:latest \
  .
```


By default, the build process of the image will install the necessary and available compiler versions for best support.
In case a smaller image is deemed necessary, pass `--build-arg="LAZY_COMPILERS=1"`.
If passed, the resulting image will install the curated list of compilers **at the first start** of the container, without occupying space in the _image_.
However, this will increase the network use and the initial deployment time of the containers.



### Setting up the worker

Alternatively, you can start the container manually, with the following arguments.
The running container will act as the master DistCC daemon of the host computer, listening on the _default_ ports `3632` and `3633`.


```bash
docker run  \
  --detach \
  --init \
  --mount type=tmpfs,destination=/tmp,tmpfs-size=8G \
  --publish 3632:3632/tcp \
  --publish 3633:3633/tcp \
  --restart unless-stopped \
  ghcr.io/whisperity/distcc-docker:ubuntu-20.04
```


The number of worker threads available for the service can be configured by passing `--jobs N` after the image name, directly to the container's _"`main()`"_ script.
The suggested _default_ is the number of CPU threads available on the machine, minus 2.
