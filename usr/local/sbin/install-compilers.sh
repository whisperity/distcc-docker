#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Install LTS compiler versions into the image (or the container).

COMPILERS_INSTALLED_STAMP="/var/lib/.distcc-compilers-done"

if [ -f "$COMPILERS_INSTALLED_STAMP" ]; then
  echo "[^:)] The compilers are already installed appropriately, skipping..." >&2
  exit 0
else
  echo "[...] Installing C, C++ compilers..." >&2
fi


set -xe

export DEBIAN_FRONTEND="noninteractive"
apt-get update -y


# Versions of GCC/G++ and Clang on LTS Ubuntus:
#   *  Ubuntu 20.04 "Focal Fossa":      GCC/G++  9        Clang 10
#   *  Ubuntu 22.04 "Jammy Jellyfish":  GCC/G++ 11        Clang 14
#   *  Ubuntu 24.04 "Noble Numbat":     GCC/G++ 13        Clang 18


OS_RELEASE="$(lsb_release -c | cut -d ':' -f 2 | xargs)"
if [[ "$OS_RELEASE" == "focal" ]]; then
  # Ubuntu 20.04 LTS "Focal Fossa".
  # This is the best approximation, as 22.04 and 24.04 do not have Clang 10
  # anymore, and 20.04 can install newer versions from PPAs.
  INSTALL_TMPDIR="$(mktemp -d)"
  pushd "$INSTALL_TMPDIR"

  apt-get install -y \
    ca-certificates \
    gpg

  # Set up LLVM and Ubuntu Toolchain Test PPA sources.
  mkdir -pv "/etc/apt/keyrings"
  wget -O- https://apt.llvm.org/llvm-snapshot.gpg.key \
    | gpg --dearmor \
    > "/etc/apt/keyrings/llvm-snapshot.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/llvm-snapshot.gpg]" \
    "http://apt.llvm.org/focal/ llvm-toolchain-focal-14 main" \
    > "/etc/apt/sources.list.d/apt-llvm-org-focal-llvm-toolchain-focal-14.list"
  echo "deb [signed-by=/etc/apt/keyrings/llvm-snapshot.gpg]" \
    "http://apt.llvm.org/focal/ llvm-toolchain-focal-18 main" \
    > "/etc/apt/sources.list.d/apt-llvm-org-focal-llvm-toolchain-focal-18.list"

  echo "deb [signed-by=/etc/apt/keyrings/ubuntu-toolchain-r.gpg]" \
    "http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu/ focal main" \
    > "/etc/apt/sources.list.d/ubuntu-toolchain-r-ubuntu-test-focal.list"
  MISSING_KEYS_FILE="$(mktemp -p $INSTALL_TMPDIR)"
  apt-get update -y \
    >>/dev/null \
    2>"$MISSING_KEYS_FILE" \
    || true
  KEY="$(cat $MISSING_KEYS_FILE \
    | grep "NO_PUBKEY" \
    | cut -d ':' -f 6 \
    | cut -d ' ' -f 3)"
  apt-key adv --keyserver "hkp://keyserver.ubuntu.com:80" --recv-keys "$KEY"
  mv "/etc/apt/trusted.gpg" "/etc/apt/keyrings/ubuntu-toolchain-r.gpg"

  apt-get update -y

  apt-get install -y --no-install-recommends \
    gcc       g++       clang \
    gcc-9     g++-9     clang-10 \
    gcc-11    g++-11    clang-14 \
    gcc-13    g++-13    clang-18

  apt-get purge -y --auto-remove \
    ca-certificates \
    gpg

  popd # $INSTALL_TMPDIR
  rm -rfv "$INSTALL_TMPDIR"
else
  set +x
  echo "[!!!] Unsupported OS release: $OS_RELEASE" >&2
  echo "[!!!] No compilers will be installed, sorry!" >&2
  exit 2
fi


update-distcc-symlinks
touch "$COMPILERS_INSTALLED_STAMP"
chmod 444 "$COMPILERS_INSTALLED_STAMP"
exit 0
