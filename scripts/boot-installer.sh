#!/usr/bin/env bash
# Boot the Gentoo minimal/admin ISO in QEMU+KVM with OVMF UEFI, virtio disk/net,
# and SSH forwarded localhost:2222 -> guest:22.
# Inside the live env: set a root password and start sshd, then run Stage A.
set -euo pipefail
cd "$(dirname "$0")/.."
ISO="${1:?usage: boot-installer.sh <gentoo-minimal.iso> [qcow2]}"
IMG="${2:-gentoo_staging.qcow2}"
# This host ships the 4M OVMF build (OVMF_CODE_4M.fd / OVMF_VARS_4M.fd).
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="OVMF_VARS.local.fd"
[ -f "$OVMF_VARS" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS"

KERNEL="iso-extract/gentoo"
INITRD="iso-extract/gentoo.igz"

exec qemu-system-x86_64 \
  -accel kvm -cpu host -m 4096 -smp 4 -machine q35 \
  -drive file="$IMG",if=virtio,format=qcow2 \
  -cdrom "$ISO" \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "root=live:CDLABEL=Gentoo-amd64-20260531 rd.live.dir=/ rd.live.squashimg=image.squashfs cdroot console=tty0 console=ttyS0,115200" \
  -display none \
  -chardev socket,id=ser0,path=/tmp/gentoo-serial.sock,server=on,wait=off \
  -serial chardev:ser0 \
  -monitor unix:/tmp/gentoo-mon.sock,server,nowait
