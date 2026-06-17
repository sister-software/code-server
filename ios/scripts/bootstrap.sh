#!/bin/sh
# First-boot setup for the iSH ARM64 Alpine guest.
#
# Baked into the image at /usr/local/bin/bootstrap.sh. Run it once from the
# terminal (as the operator user; it uses passwordless sudo for apk):
#
#   bootstrap.sh
#
# Idempotent — safe to re-run. Extend the package list / config below as needed.
set -eu

echo "==> Updating package index…"
sudo apk update

echo "==> Installing dev tooling…"
sudo apk add \
  gcc \
  tmux \
  ripgrep \
  htop \
  make \
  cmake

echo "==> Done. Installed: gcc tmux ripgrep htop make cmake"
