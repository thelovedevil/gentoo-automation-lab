# Architecture

## Build Pipeline

The pipeline is a **two-phase, three-stage** process:

### Phase 1: Virtual Build Oven (QEMU/KVM)

The build host runs QEMU/KVM with nested virtualization (WSL2 or native Linux). The guest gets 4GB RAM, 4 vCPUs, and a 40GB qcow2 disk image. All compilation targets `-march=x86-64-v3` (AVX2/AES-NI/BMI2) — the common denominator between the VM and modern x86-64 hardware.

**Stage A** boots the Gentoo minimal ISO via direct kernel boot (extracted vmlinuz + initrd, serial console over Unix socket). Ansible connects to the ISO's sshd on `localhost:2222` and drives the entire install:

```
ISO boot → passwd/sshd → Ansible SSH →
  sgdisk GPT → mkfs → stage3 unpack → chroot →
  make.conf → emerge-webrsync → emerge kernel →
  dracut initramfs → grub-install UEFI → fstab PARTUUID
```

**Stage B** reboots into the installed Gentoo (OVMF firmware → GRUB → kernel). Ansible reconnects and provisions the full workstation environment across 8 roles, compiling ~250 packages from source.

### Phase 2: Metal Deployment

The qcow2 is converted to raw and flashed to an external SSD. The LUKS playbook then performs in-place encryption from a live USB environment:

```
Live USB boot → mount unencrypted root →
  tar backup → unmount → cryptsetup luksFormat →
  luksOpen → mkfs → tar restore →
  update fstab/crypttab → dracut --add crypt →
  grub-install --modules="luks2 cryptodisk" →
  grub-mkconfig → reboot encrypted
```

## Kernel Strategy

### Phase 1: Distribution Kernel
Uses `sys-kernel/gentoo-kernel` (pre-configured, broad hardware support) with a config fragment overlay:

- **Security**: TOMOYO LSM enabled
- **Storage**: VirtIO-blk, NVMe, AHCI as builtins (not modules) — boots on any controller
- **Networking**: Advanced router, multiple routing tables, conntrack, traffic qdiscs, network namespaces
- **Initramfs**: dracut `hostonly=no` — carries all drivers, not just detected ones

### Phase 2: Custom Kernel
Switches to `sys-kernel/gentoo-sources` for hand-tuned `.config`:
- `-march=native` (P/E-core aware scheduling)
- `PREEMPT_RT` for timing-sensitive operations
- eBPF/XDP for programmable packet processing (see [eBPF Stack](#ebpf-stack) below)
- Hardware-specific GPU, NIC, and sensor drivers

## NVIDIA on PREEMPT_RT

A non-obvious problem: NVIDIA's proprietary driver refuses to load on `PREEMPT_RT` kernels by default — the installer checks for RT and aborts, because NVIDIA's kernel module uses spinlocks and memory allocation patterns that conflict with RT's sleeping-spinlock semantics.

The solution is a three-layer approach deployed across Gentoo's configuration system:

```
/etc/env.d/50nvidia              ← IGNORE_PREEMPT_RT_PRESENCE=1
  ↓ env-update
/etc/profile.env                 ← exported to all login shells
  ↓
nvidia.ko loads on PREEMPT_RT    ← driver skips RT presence check
```

**Why this works:** `IGNORE_PREEMPT_RT_PRESENCE=1` tells the NVIDIA driver to skip its RT kernel detection. The driver functions correctly on RT kernels for GPU compute and display — the spinlock concern is theoretical for workstation use (not hard-realtime control systems). Gentoo's `env.d` mechanism ensures the variable is set system-wide before any module loading.

**Supporting configuration:**

| File | Purpose |
|---|---|
| `/etc/env.d/50nvidia` | `IGNORE_PREEMPT_RT_PRESENCE=1` — survives upgrades |
| `/etc/modprobe.d/nvidia.conf` | Module options: suspend notifiers, device file permissions (GID=video) |
| `/etc/modprobe.d/blacklist-nouveau.conf` | Prevent open-source driver from racing nvidia.ko |
| `/etc/X11/xorg.conf.d/10-nvidia.conf` | Xorg `Driver "nvidia"` with `NoLogo` |
| `make.conf` | `VIDEO_CARDS="nvidia"` — ensures portage builds GPU-aware packages |

**GRUB kernel selection:** When multiple kernels are installed (e.g., `gentoo-dist` for fallback + `gentoo-sources` for RT), `GRUB_DEFAULT` uses the nested submenu ID syntax to target the kernel whose modules match the installed NVIDIA driver version:

```
GRUB_DEFAULT="<submenu-id>/<entry-id>"
```

This prevents boot into a kernel where `nvidia.ko` wasn't built, which would silently fall back to software rendering.

## eBPF Stack

The kernel ships full eBPF support as builtins (not modules), enabling programmable packet processing and observability without recompilation:

| Feature | Config | Use Case |
|---|---|---|
| BPF syscall + JIT | `CONFIG_BPF_SYSCALL=y`, `BPF_JIT_ALWAYS_ON` | Core eBPF execution engine |
| BPF LSM | `CONFIG_BPF_LSM=y` | Security policy via BPF programs (complements TOMOYO) |
| XDP sockets | `CONFIG_XDP_SOCKETS=y` | High-performance packet processing before the network stack |
| Kprobes/Uprobes | `CONFIG_KPROBES=y`, `CONFIG_UPROBES=y` | Dynamic kernel/userspace tracing |
| BTF (CO-RE) | `CONFIG_DEBUG_INFO_BTF=y` | Compile-once-run-everywhere BPF programs across kernel versions |
| Cgroup BPF | `CONFIG_CGROUP_BPF=y` | Per-cgroup network/device policy |
| Net classifier | `CONFIG_NET_CLS_BPF=m` | TC/traffic-control integration |

Userspace tools (`bpftool`, `bpftrace`, `bcc`) are installed at first boot. The combination of eBPF + XDP + PREEMPT_RT enables low-latency programmable networking — timing-sensitive packet manipulation with deterministic scheduling guarantees.

## Security Model

### TOMOYO MAC
Mandatory access control in learning mode from first boot. TOMOYO observes all process behavior and auto-generates domain policies. After baseline is established, policies are tightened to enforcement mode — any process attempting unauthorized file/network/IPC access is denied.

### SSH Hardening
Progressive lockdown: Stage A allows root password auth (build oven only). Stage B deploys operator SSH pubkey and switches to `PermitRootLogin prohibit-password` + `PasswordAuthentication no` + `MaxAuthTries 3`.

### LUKS2 + LVM
Full-disk encryption (AES-XTS-512, argon2id KDF) applied at deployment time with LVM inside the LUKS container:

```
ESP (512M, vfat) — unencrypted
Partition 2 → LUKS2 (aes-xts-plain64, argon2id)
  └─ VG: gentoo
       ├─ LV: root   (60GB, ext4)   — OS + packages
       ├─ LV: swap   (8GB)          — matches RAM
       └─ LV: home   (remainder)    — user data, projects, models
```

GRUB unlocks LUKS pre-boot via `cryptodisk` module with embedded `luks2`, `gcry_rijndael`, `gcry_sha512`, and `lvm` modules. Dracut initramfs is built with `hostonly=no` and carries `crypt`, `dm`, and `lvm` modules plus dual drivers (virtio + metal: NVMe, AHCI, dm-crypt) to activate the volume group after unlock on any hardware. fstab is keyed on UUID (not `/dev/gentoo/*` device paths) for portability. ESP remains unencrypted (contains only GRUB + kernel, no secrets).

### Firewall (nftables)
Default-drop input policy with explicit allows for established connections and rate-limited SSH (3/minute). Deployed in Phase 1.5 before metal flash.

### Kernel Hardening (sysctl + boot params)
Hardened via sysctl (`kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=2`, `unprivileged_bpf_disabled=1`, `tcp_timestamps=0`) and GRUB cmdline (`init_on_alloc=1`, `init_on_free=1`, `slab_nomerge`, `page_alloc.shuffle=1`, `vsyscall=none`).

## LLM Runtime Architecture

```
/opt/llm-venv/              ← Python 3.13 virtual environment
├── langchain-core           ← Orchestration framework
├── langgraph                ← Stateful agent graphs
├── langchain-anthropic      ← Claude API integration
├── langchain-ollama         ← Local model serving
├── llama-cpp-python         ← Local inference (CPU in Phase 1, CUDA in Phase 2)
└── anthropic                ← Direct API client
```

The runtime is split by latency requirements:
- **Local inference** (llama.cpp): fast, private, offline-capable — runs quantized models on available hardware
- **Cloud inference** (Claude API): high-capability reasoning for complex decisions
- **Orchestration** (LangGraph): stateful agent graphs that route between local and cloud based on task complexity

## Offensive Toolchain Tiers

The security toolchain spans four installation methods because Gentoo's stable tree doesn't package most modern security tools:

| Tier | Method | Tools | Rationale |
|---|---|---|---|
| 1 | Portage (`emerge`) | nmap, masscan, hydra, hashcat, sqlmap, nikto | Stable, system-integrated, auto-updated |
| 2 | Go (`go install`) | nuclei, httpx, subfinder, katana, ffuf, gobuster, dalfox, dnsx, puredns | Not in portage; Go's static linking = zero dep conflicts |
| 3 | Rust (`cargo install`) | feroxbuster, rustscan | Performance-critical tools; Rust's safety + speed |
| 4 | Pip (isolated venv) | arjun | Python tools isolated from system Python |

SecLists wordlists are cloned from GitHub to `/opt/seclists`.

## Desktop Environment

Minimal tiling WM stack optimized for keyboard-driven security workflows:

```
xinit → bspwm (window manager)
         ├── sxhkd (hotkey daemon)
         ├── picom (compositor — transparency, shadows)
         ├── polybar (status bar)
         └── sakura (terminal emulator)
```

Emacs runs as the primary editor/IDE with:
- **Eglot** LSP client (clangd for C/C++, pylsp for Python)
- **vterm** terminal emulator (libvterm-backed, full shell inside Emacs)
- **Magit** for Git operations
- **gptel** for LLM integration (Ollama + cloud providers)
- **Vertico/Orderless/Marginalia** completion framework
- Literate configuration via Org-mode (`config.org` → `config.el`)
