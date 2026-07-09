#!/bin/bash
# first-boot.sh — Run once on metal after LUKS boot. Sets up full dev environment.
# Usage: sudo ./first-boot.sh
#
# Idempotent: safe to re-run. Uses --noreplace and existence checks throughout.
set -euo pipefail

OPERATOR_USER="${OPERATOR_USER:-operator}"
PROJECTS_DIR="/home/${OPERATOR_USER}/projects"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

step() { echo -e "\n${GRN}[*]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
fail() { echo -e "${RED}[X]${NC} $1"; exit 1; }

# ---- Phase 0: NVIDIA + OpenGL ----
step "Setting up NVIDIA OpenGL provider"
emerge --noreplace app-eselect/eselect-opengl
eselect opengl set nvidia
modprobe nvidia && nvidia-smi && step "NVIDIA driver loaded" || warn "NVIDIA modprobe failed — check kernel/driver match"

# ---- Phase 1: System packages ----
step "Syncing librewolf overlay"
emaint sync -r librewolf

step "Installing Node.js + GitHub CLI + LibreWolf + eBPF tools"
emerge --noreplace net-libs/nodejs dev-vcs/gh www-client/librewolf \
    dev-util/bpftool dev-util/bpftrace dev-util/bcc

step "Verifying installations"
node --version || fail "Node.js install failed"
npm --version || fail "npm not available"
gh --version || fail "gh install failed"

# ---- Phase 2: GitHub auth ----
step "Authenticating with GitHub"
if gh auth status &>/dev/null; then
    step "Already authenticated with gh"
else
    warn "You need to authenticate with GitHub."
    warn "Choose HTTPS + browser/token when prompted."
    gh auth login -h github.com -p https
fi

# ---- Phase 3: Clone repos ----
step "Cloning project repositories"
mkdir -p "$PROJECTS_DIR"
cd "$PROJECTS_DIR"

# Add your repositories here as [directory]="owner/repo"
declare -A REPOS=(
    # [my-project]="my-org/my-project"
)

for dir in "${!REPOS[@]}"; do
    if [ -d "$dir/.git" ]; then
        step "  $dir — already cloned, pulling latest"
        git -C "$dir" pull --ff-only 2>/dev/null || warn "  $dir pull failed (check branch state)"
    else
        step "  Cloning $dir"
        gh repo clone "${REPOS[$dir]}" "$dir" -- --recurse-submodules || warn "  Failed to clone $dir"
    fi
done

# ---- Phase 4: Dev tools ----
step "Installing Claude Code"
npx @anthropic-ai/claude-code@latest --version || warn "Claude Code install/check failed"

# ---- Phase 5: API Key ----
BASHRC="/home/${OPERATOR_USER}/.bashrc"
if grep -q 'ANTHROPIC_API_KEY' "$BASHRC" 2>/dev/null; then
    step "ANTHROPIC_API_KEY already in .bashrc"
else
    warn "Set your Anthropic API key:"
    echo -e "  ${YEL}echo 'export ANTHROPIC_API_KEY=\"sk-ant-...\"' >> ~/.bashrc${NC}"
    echo -e "  ${YEL}source ~/.bashrc${NC}"
fi

# ---- Phase 6: Fix ownership ----
step "Fixing ownership on /home/${OPERATOR_USER}"
chown -R "${OPERATOR_USER}:${OPERATOR_USER}" "/home/${OPERATOR_USER}"

# ---- Summary ----
echo ""
step "=============================="
step "  First-boot setup complete"
step "=============================="
echo ""
echo "  Remaining manual steps:"
echo "    1. Set ANTHROPIC_API_KEY in ~/.bashrc (if not done above)"
echo "    2. source ~/.bashrc"
echo "    3. cd ~/projects && claude"
echo ""
echo "  To verify NVIDIA:"
echo "    nvidia-smi"
echo "    startx  (should launch bspwm desktop)"
echo ""
echo "  To verify eBPF:"
echo "    bpftool prog list"
echo "    bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf(\"%s %s\\n\", comm, str(args.filename)); }'"
echo ""
