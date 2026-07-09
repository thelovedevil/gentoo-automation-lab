# NVIDIA Driver on PREEMPT_RT Gentoo Kernels

## The Problem

NVIDIA's proprietary kernel module (`nvidia.ko`) refuses to load on `PREEMPT_RT` kernels. The driver's build system and init path check for RT and abort:

```
FATAL: modpost: GPL-incompatible module nvidia.ko uses GPL-only symbol 'preempt_count'
```

Or at runtime:
```
nvidia: disagrees about version of symbol module_layout
```

This is because NVIDIA's module uses raw spinlocks and non-deterministic memory allocation that conflict with RT's sleeping-spinlock model. NVIDIA officially does not support RT kernels.

## Why You Want Both

`PREEMPT_RT` provides deterministic scheduling — critical for:
- **Timing-sensitive packet manipulation** (eBPF/XDP programs with hard latency bounds)
- **Real-time signal processing** (SDR, audio)
- **Deterministic network operations** (traffic shaping, coordinated egress timing)

NVIDIA GPU provides:
- **CUDA compute** for ML inference (local LLM via llama.cpp)
- **Hardware-accelerated desktop** (compositor, browser rendering)

Dropping either capability is unacceptable for an offensive-security workstation that needs both GPU compute and low-latency networking.

## The Solution

### 1. Environment Variable (`/etc/env.d/50nvidia`)

```bash
IGNORE_PREEMPT_RT_PRESENCE=1
```

Gentoo's `env.d` system is the correct place — not `.bashrc` or `/etc/environment`. Running `env-update` bakes it into `/etc/profile.env`, which is sourced by all login shells and by OpenRC service scripts before any module loading occurs.

```bash
# Set the variable
echo 'IGNORE_PREEMPT_RT_PRESENCE=1' > /etc/env.d/50nvidia

# Regenerate profile.env (also rebuilds ld.so.cache)
env-update && source /etc/profile
```

### 2. Module Configuration (`/etc/modprobe.d/nvidia.conf`)

```conf
# Suspend/resume support (kernel notifiers, no systemd services needed)
options nvidia NVreg_UseKernelSuspendNotifiers=1 NVreg_TemporaryFilePath=/var/tmp

# Device file permissions (GID=27 = video group on Gentoo)
options nvidia NVreg_DeviceFileGID=27 NVreg_DeviceFileMode=432 \
    NVreg_DeviceFileUID=0 NVreg_ModifyDeviceFiles=1

# Module dependency chain
alias char-major-195 nvidia
remove nvidia modprobe -r --ignore-remove nvidia-drm nvidia-modeset nvidia-uvm nvidia
```

### 3. Nouveau Blacklist (`/etc/modprobe.d/blacklist-nouveau.conf`)

```conf
blacklist nouveau
options nouveau modeset=0
```

Without this, nouveau can race nvidia.ko for the GPU and cause a hard lockup on boot.

### 4. Xorg Configuration (`/etc/X11/xorg.conf.d/10-nvidia.conf`)

```conf
Section "Device"
    Identifier  "NVIDIA"
    Driver      "nvidia"
    Option      "NoLogo" "true"
EndSection
```

Explicit driver selection prevents Xorg from falling back to modesetting (which won't use the GPU).

### 5. Portage Integration (`make.conf`)

```bash
VIDEO_CARDS="nvidia"
INPUT_DEVICES="libinput"
```

Ensures all packages with optional GPU support (mesa, ffmpeg, etc.) build their NVIDIA codepaths.

### 6. OpenGL Provider

```bash
emerge app-eselect/eselect-opengl
eselect opengl set nvidia
```

Without this, applications link against mesa's software OpenGL instead of NVIDIA's hardware implementation.

### 7. GRUB Kernel Selection

When multiple kernels coexist (distribution kernel for fallback + custom RT kernel), GRUB must boot the kernel whose `/lib/modules/<version>/` contains `nvidia.ko`. Use the nested submenu ID syntax:

```bash
GRUB_DEFAULT="<submenu-id>/<kernel-entry-id>"
```

Then regenerate: `grub-mkconfig -o /boot/grub/grub.cfg`

## Verification

```bash
# Module loads
modprobe nvidia && echo "OK"

# GPU visible
nvidia-smi

# Xorg uses nvidia (not modesetting)
startx
# In a terminal:
glxinfo | grep "OpenGL renderer"
# Should show: "NVIDIA GeForce RTX ..."
```

## Caveats

- **Not officially supported by NVIDIA.** The `IGNORE_PREEMPT_RT_PRESENCE` flag bypasses a safety check. This is acceptable for workstation/compute use but not for hard-realtime control systems where a GPU driver stall could violate timing constraints.
- **Rebuild on kernel upgrade:** `emerge @module-rebuild` after any kernel version change, or nvidia.ko will fail to load (version mismatch).
- **Driver version pinning:** Pin `x11-drivers/nvidia-drivers` in `/etc/portage/package.mask` if you need stability across kernel upgrades.
