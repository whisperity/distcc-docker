# SPDX-License-Identifier: MIT

FROM ubuntu:20.04
MAINTAINER Whisperity <whisperity-packages@protonmail.com>


RUN \
  export DEBIAN_FRONTEND=noninteractive && \
  set -x && \
  apt-get update -y && \
  apt-get install -y --no-install-recommends \
    cron \
    curl \
    distcc \
    htop \
    lsb-release \
    locales \
    logrotate \
    python3 \
    wget \
  && \
  apt-get purge -y --auto-remove && \
  apt-get clean && \
  rm -rf "/var/lib/apt/lists/" && \
  rm -rf "/var/log/" && \
  mkdir -pv "/var/log/" && \
  chmod -v -x \
    "/etc/cron.daily/apt-compat" \
    "/etc/cron.daily/dpkg"


RUN \
  export DEBIAN_FRONTEND=noninteractive; \
  sed -i -e "s/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" "/etc/locale.gen" && \
  dpkg-reconfigure --frontend=noninteractive locales && \
  update-locale LANG="en_US.UTF-8"
ENV \
  LANG="en_US.UTF-8" \
  LANGUAGE="en_US:en" \
  LC_ALL="en_US.UTF-8"


COPY usr/local/sbin/install-compilers.sh /usr/local/sbin/install-compilers.sh

# Set to non-zero if the compilers should only be installed into the container,
# and not immediately baked into the image itself.
ARG LAZY_COMPILERS=0
RUN \
  if [ "x$LAZY_COMPILERS" = "x0" ]; \
  then \
    set -x && \
    /usr/local/sbin/install-compilers.sh && \
    apt-get purge -y --auto-remove && \
    apt-get clean && \
    rm -rf "/var/lib/apt/lists/" && \
    rm -rf "/var/log/" && \
    mkdir -pv "/var/log/"; \
  fi


COPY etc/ /etc/
COPY usr/ /usr/


ARG USERNAME="distcc"
RUN \
  cp -av "/etc/skel/." "/root/" && \
  echo "Creating service user: $USERNAME ..." >&2 && \
  useradd "$USERNAME" \
    --create-home \
    --comment "DistCC service" \
    --home-dir "/var/lib/distcc/" \
    --shell "/bin/bash" \
    --system \
    && \
  chown -Rv "$USERNAME":"$USERNAME" "/var/lib/distcc" && \
  echo "$USERNAME" > "/var/lib/distcc/distcc.user" && \
  chmod -v 444 "/var/lib/distcc/distcc.user"


# Expose the DistCC server's normal job and statistics subservice port.
# Custom ports to be used on the host machine should be managed via Docker.
EXPOSE \
  3632/tcp \
  3633/tcp


HEALTHCHECK \
  --interval=5m \
  --timeout=15s \
  CMD \
    curl -f http://0.0.0.0:3633/ || exit 1


ENTRYPOINT ["/usr/local/sbin/container-main.sh"]
