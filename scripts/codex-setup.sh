#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y \
  build-essential clang flex bison g++ gawk gcc-multilib gettext git \
  libncurses-dev libssl-dev python3 python3-setuptools python3-pyelftools \
  rsync swig unzip zlib1g-dev file wget curl libelf-dev ecj fastjar \
  xsltproc qemu-utils ccache jq

# GitHub Contents API-created shell scripts may not carry the executable bit.
# Normalize project script permissions before running any static verification.
chmod +x scripts/*.sh
