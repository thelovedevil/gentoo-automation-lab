#!/usr/bin/env bash
# Create the portable qcow2 image.
set -euo pipefail
cd "$(dirname "$0")/.."
IMG="${1:-gentoo_staging.qcow2}"
SIZE="${2:-40G}"
qemu-img create -f qcow2 "$IMG" "$SIZE"
echo "created $IMG ($SIZE)"
