#!/usr/bin/env bash
# Boot the INSTALLED Gentoo from qcow2 (no ISO, no -kernel/-initrd).
# GRUB in the ESP chains the kernel. OVMF UEFI firmware.
set -euo pipefail
cd "$(dirname "$0")/.."
IMG="${1:-gentoo_staging.qcow2}"

OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="OVMF_VARS.local.fd"
# Always start with fresh NVRAM so boot order is clean
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"

exec qemu-system-x86_64 \
  -accel kvm -cpu host -m 4096 -smp 4 -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive id=disk0,file="$IMG",if=none,format=qcow2 \
  -device virtio-blk-pci,drive=disk0,bootindex=1 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -display none \
  -chardev socket,id=ser0,path=/tmp/gentoo-serial.sock,server=on,wait=off \
  -serial chardev:ser0 \
  -monitor unix:/tmp/gentoo-mon.sock,server,nowait
