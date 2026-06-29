# gentoo-automation-lab

**Ansible-driven pipeline that bakes a portable, hardened Gentoo Linux image in a local QEMU/KVM build oven — ready for bare-metal deployment with full-disk encryption.**

> A complete infrastructure-as-code approach to Gentoo installation: from empty disk image to fully provisioned offensive-security workstation with tiling WM, LLM orchestration stack, and TOMOYO MAC hardening — entirely automated, reproducible, and idempotent.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        BUILD HOST (WSL2/Linux)                  │
│                                                                 │
│   ansible-playbook ──SSH:2222──► QEMU/KVM Guest (4GB / 4 vCPU) │
│                                                                 │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │  Stage A (ISO-driven)           Stage B (installed OS)   │  │
│   │  ┌──────────────────┐           ┌─────────────────────┐  │  │
│   │  │ 1. GPT + UEFI    │           │ 6. CLI utilities    │  │  │
│   │  │ 2. stage3 fetch  │  reboot   │ 7. Networking/VPN   │  │  │
│   │  │ 3. Portage sync  │ ────────► │ 8. Desktop (bspwm)  │  │  │
│   │  │ 4. Kernel build  │           │ 9. Emacs + LSP      │  │  │
│   │  │ 5. GRUB UEFI     │           │10. LLM runtime      │  │  │
│   │  └──────────────────┘           │11. Offensive tools   │  │  │
│   │                                 │12. Dotfiles          │  │  │
│   │                                 │13. TOMOYO hardening  │  │  │
│   │                                 └─────────────────────┘  │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│   Phase 2 (metal): flash to SSD ──► LUKS encrypt ──► tune      │
└─────────────────────────────────────────────────────────────────┘
```

## Why This Exists

Standard Gentoo installation is a manual, error-prone, multi-hour process. This project replaces it with a **deterministic two-stage Ansible pipeline** that:

- Builds a **portable image** (`-march=x86-64-v3`) in a QEMU/KVM oven that boots on *any* modern x86-64 hardware
- Provisions a **complete offensive-security workstation** with 30+ tools across four installation tiers (portage, Go, Rust, pip)
- Deploys an **LLM orchestration runtime** (LangChain/LangGraph + local inference via llama.cpp)
- Applies **mandatory access control** (TOMOYO) and SSH hardening from first boot
- Supports **Phase 2 migration** to bare metal with in-place LUKS2 encryption

## Hard Invariants

These constraints ensure one image boots both the QEMU oven and any target hardware:

| Invariant | Rationale |
|---|---|
| `-march=x86-64-v3` only, never `-march=native` | Portable binaries; native tuning is a Phase 2 additive step |
| GPT + UEFI + real ESP | ESP transfers as-is to metal; GRUB `--removable` boots arbitrary firmware |
| fstab/bootloader keyed on `PARTUUID` | Device names change across hardware (`vda` → `nvme0n1` → `sda`) |
| Kernel + initramfs carry virtio AND metal drivers | `dracut --no-hostonly` builds a generic initramfs with NVMe, AHCI, common NICs |
| OpenRC + minimal USE flags | Clean baseline; small attack surface |

## Roles

### Stage A — Bake (ISO-driven, chroot into empty disk)

| Role | What it does |
|---|---|
| `partition` | GPT via sgdisk: 512M ESP (vfat) + root (ext4), PARTUUID capture |
| `stage3` | Fetch latest stage3 tarball, GPG-verify signature, unpack |
| `portage` | make.conf, repos.conf, bind-mount pseudofs, `emerge-webrsync` |
| `kernel` | Distribution kernel (`gentoo-kernel`) + config fragment (TOMOYO, net knobs, dual-driver builtin), dracut generic initramfs |
| `bootloader` | GRUB UEFI `--removable`, PARTUUID fstab, dhcpcd+sshd enable, root credential |

### Stage B — Provision (booted installed OS, normal SSH)

| Role | What it does |
|---|---|
| `cli` | tmux, ripgrep, fd, jq, htop, bash-completion |
| `networking` | WireGuard, Tor, proxychains, OpenVPN, socat, tcpdump, Wireshark (CLI), curl |
| `desktop` | Xorg (modesetting), bspwm, sxhkd, sakura, picom, polybar, dmenu, fonts |
| `editor` | Emacs (X11 GUI) + clangd (C/C++ LSP) + pylsp (Python LSP) + libvterm |
| `runtime` | Python 3.13 venv with LangChain, LangGraph, Anthropic SDK, Ollama, llama-cpp-python (CPU) |
| `offensive` | **Portage:** nmap, masscan, nikto, hydra, hashcat, sqlmap · **Go:** nuclei, httpx, subfinder, katana, ffuf, gobuster, dalfox, puredns, dnsx · **Rust:** feroxbuster, rustscan · **Pip:** arjun · **Git:** SecLists |
| `dotfiles` | Emacs literate config (Org-mode), custom theme, tool configs (recon scanner profiles) |
| `hardening` | TOMOYO MAC (learning mode on first boot), sshd lockdown (key-only when pubkey provided) |

### Phase 1.5 — Pre-Flash Hardening (`phase1_5_harden.yml`)

Applied before flashing to metal — maximizes what's portable:

| Area | What |
|---|---|
| Browser | LibreWolf (privacy-hardened Firefox fork via overlay) |
| Desktop | bspwm theming (custom color palette, picom translucency 85-92%, kawase blur, polybar), sxhkd keybinds, Xresources terminal colors, GTK dark theme |
| Firewall | nftables baseline (default-drop input, rate-limited SSH/ICMP, log drops) |
| Kernel hardening | sysctl (kptr_restrict, dmesg_restrict, ptrace_scope=2, unprivileged_bpf_disabled, tcp_timestamps=0) + GRUB cmdline (init_on_alloc/free, slab_nomerge, vsyscall=none) |
| DNS privacy | DNS-over-TLS resolver (stubby) |
| Security tools | lynis (audit), firejail (sandboxing), doas (minimal sudo), gnupg |
| Shell | Custom .bashrc with tool aliases, history hardening, PATH wiring |
| Network prep | Ansible control node, SSH config for FreeBSD/pfSense targets |
| LLM prep | Ollama OpenRC init script, environment variables |

### Phase 2 — Metal Deployment

| Role | What it does |
|---|---|
| `luks` | In-place LUKS2 + LVM encryption: backup rootfs → `cryptsetup luksFormat` (AES-XTS-512, argon2id) → LVM (root + swap + home) → restore → dracut crypt+lvm modules → GRUB `cryptodisk` with LVM support |

## Project Structure

```
├── ansible.cfg
├── inventory.ini                # QEMU guest (localhost:2222)
├── inventory_metal.ini          # Phase 2 metal target
├── group_vars/
│   └── all.yml                  # Single source of truth (all tunables)
├── stage_a_bake.yml             # Stage A playbook (ISO → installed OS)
├── base_provision.yml           # Stage B playbook (provision the OS)
├── phase1_5_harden.yml          # Pre-flash hardening (desktop, firewall, etc.)
├── phase2_luks.yml              # Phase 2 LUKS + LVM encryption
├── stage_a_resume.yml           # Resume Stage A (skip partition/stage3)
├── stage_a_bootloader.yml       # Re-run bootloader only
├── roles/
│   ├── partition/               # GPT + format + PARTUUID
│   ├── stage3/                  # Fetch + GPG-verify + unpack
│   ├── portage/                 # make.conf + chroot + webrsync
│   ├── kernel/                  # Distribution kernel + dracut
│   ├── bootloader/              # GRUB UEFI + fstab
│   ├── cli/                     # Shell utilities
│   ├── networking/              # VPN + anonymity + packet tools
│   ├── desktop/                 # bspwm + Xorg + compositor
│   ├── editor/                  # Emacs + LSP
│   ├── runtime/                 # Python + LLM stack
│   ├── offensive/               # 4-tier offensive toolchain
│   ├── dotfiles/                # Editor + tool config deployment
│   ├── hardening/               # TOMOYO + sshd
│   └── luks/                    # Phase 2 LUKS encryption
├── templates/
│   ├── make.conf.j2
│   ├── fstab.j2
│   └── dracut.conf.j2
└── scripts/
    ├── create-disk.sh           # qemu-img create
    ├── boot-installer.sh        # Boot ISO (Stage A)
    └── boot-installed.sh        # Boot installed OS (Stage B / testing)
```

## Key Design Decisions

### Two-Stage Split
Ansible requires SSH access, but a fresh disk has no OS. Stage A boots the Gentoo minimal ISO in QEMU (which ships sshd), then Ansible drives the full install via chroot. Stage B reboots into the installed system and provisions normally.

### Four-Tier Offensive Toolchain
Not all security tools are in Gentoo's portage tree. The offensive role installs from four sources in order:
1. **Portage** — nmap, hydra, hashcat, sqlmap, masscan, nikto (stable, maintained)
2. **Go** — ProjectDiscovery suite (nuclei, httpx, katana, subfinder), ffuf, gobuster (latest from source)
3. **Rust** — feroxbuster, rustscan (`cargo install`)
4. **Pip** — arjun, specialized Python tools (in isolated venv)

### LLM Runtime
The image ships a Python venv with the full LangChain/LangGraph stack plus llama-cpp-python for local inference. GPU acceleration (CUDA) is deferred to Phase 2 when running on metal with a dedicated GPU. The architecture separates the orchestration layer (portable) from the compute backend (hardware-specific).

### LUKS Phase 2
Encryption is a deployment-time concern, not a build-time one. The Phase 2 LUKS playbook performs in-place encryption on the target disk: backup → encrypt → restore → rebuild initramfs with `crypt` module → GRUB `cryptodisk`. This avoids passphrase prompts during the VM build cycle while ensuring the production deployment is fully encrypted.

### Kernel Configuration
The distribution kernel (`gentoo-kernel`) is used for portability. A config fragment merges TOMOYO LSM, advanced networking knobs (policy routing, conntrack, qdiscs, netns), and both virtio and metal storage/NIC drivers as builtins. Phase 2 switches to `gentoo-sources` for hand-rolled kernel tuning.

## Lessons Learned

- **OOM during kernel compile**: 4GB VM with `-j5` OOM-kills `cc1` on the Intel ICE driver. Fix: 2GB swap + `-j3`
- **LLVM/Clang compile time**: ~5 hours in nested KVM with 4 vCPUs. Ansible async timeouts (even at 4h) are insufficient — heavy emerges run directly on the guest
- **Gentoo package naming**: Kali/Debian package names don't map 1:1 to portage atoms (e.g., `john` → `app-crypt/johntheripper-jumbo`, `proxychains` → `net-misc/proxychains`)
- **~amd64 masking**: Most offensive tools require `ACCEPT_KEYWORDS="~amd64"` in Gentoo's stable tree
- **USE flag cascades**: Enabling `X` triggers transitive deps (freetype needs harfbuzz, zlib needs minizip, xmlto needs text) — pre-seed `package.use` before large emerge runs

## Prerequisites

```bash
# QEMU/KVM + OVMF UEFI firmware
sudo apt install -y qemu-system-x86 qemu-utils ovmf
sudo usermod -aG kvm "$USER"   # re-login required

# Ansible
pip install ansible

# Verify
[ -r /dev/kvm ] && echo "KVM ready"
```

## Usage

```bash
# 1. Create the disk image
scripts/create-disk.sh

# 2. Download Gentoo minimal ISO
# (from https://www.gentoo.org/downloads/)

# 3. Stage A — bake the base image
scripts/boot-installer.sh install-amd64-minimal-*.iso
# In the serial console: set root password, start sshd
ansible-playbook -i inventory.ini stage_a_bake.yml -e ansible_ssh_pass=<pw>

# 4. Reboot into installed OS
scripts/boot-installed.sh

# 5. Stage B — full provision
ansible-playbook -i inventory.ini base_provision.yml -e ansible_ssh_pass=<pw>

# 6. Phase 2 — flash to SSD and encrypt (on metal, from live USB)
qemu-img convert -O raw gentoo_staging.qcow2 /dev/sdX
ansible-playbook -i inventory_metal.ini phase2_luks.yml \
  -e luks_target_disk=/dev/sdX \
  -e luks_passphrase=<passphrase>
```

## Technology Stack

Ansible · QEMU/KVM · OVMF (UEFI) · Gentoo Linux · OpenRC · GRUB2 · dracut · TOMOYO · LUKS2/cryptsetup · bspwm · Emacs · LangChain · LangGraph · Python · Go · Rust · Portage

## License

MIT
