#!/bin/bash
# first-boot.sh — Run once on metal after LUKS boot. Sets up full dev environment.
# Usage: sudo ./first-boot.sh
#
# Idempotent: safe to re-run. Uses --noreplace and existence checks throughout.
set -o pipefail

OPERATOR_USER="${OPERATOR_USER:-operator}"
PROJECTS_DIR="/home/${OPERATOR_USER}/projects"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

step() { echo -e "\n${GRN}[*]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; ((WARN++)) || true; }
fail() { echo -e "${RED}[X]${NC} $1"; ((FAIL++)) || true; }
ok()   { ((PASS++)) || true; }

[[ $EUID -eq 0 ]] || { echo "Must run as root"; exit 1; }

LOGFILE="/var/log/first-boot.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== Run started: $(date -Iseconds) ==="

# Helper: emerge a single package, skip if already installed
emerge_pkg() {
    local atom="$1"
    local cat="${atom%/*}"
    local pn="${atom##*/}"
    local found=0
    for repo_dir in /var/db/repos/*/; do
        if ls "${repo_dir}${cat}/${pn}"/*.ebuild &>/dev/null; then
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        fail "${atom} — no ebuilds found in any repo, skipping"
        return 1
    fi
    if ls /var/db/pkg/"${cat}"/"${pn}"-* &>/dev/null; then
        step "  ${atom} — already installed"
        ok
        return 0
    fi
    step "  Emerging ${atom}"
    if emerge --noreplace "${atom}"; then
        ok
        return 0
    else
        fail "  ${atom} — emerge failed (check /var/log/emerge.log)"
        return 1
    fi
}

# sophie-resolve wrapper — batch emerge with auto-retry and conflict resolution
sophie_emerge() {
    # Usage: sophie_emerge atom1 atom2 atom3 ...
    # Falls back to individual emerge_pkg if sophie-resolve is not installed
    if command -v sophie-resolve &>/dev/null; then
        step "Using sophie-resolve for batch emerge"
        if sophie-resolve emerge "$@"; then
            ok
        else
            fail "sophie-resolve emerge had failures (see output above)"
            return 1
        fi
    else
        warn "sophie-resolve not installed — falling back to individual emerge"
        local failures=0
        for atom in "$@"; do
            emerge_pkg "${atom}" || ((failures++)) || true
        done
        if [[ $failures -gt 0 ]]; then
            fail "${failures} package(s) failed in fallback mode"
            return 1
        fi
    fi
}

# ---- Phase 0: NVIDIA ----
step "Loading NVIDIA driver"
if modprobe nvidia 2>/dev/null && nvidia-smi &>/dev/null; then
    step "NVIDIA driver loaded"; ok
else
    warn "NVIDIA modprobe failed — check kernel/driver match"
fi
if eselect opengl list &>/dev/null; then
    eselect opengl set nvidia && step "OpenGL provider set to nvidia"
else
    step "eselect opengl not available — nvidia-drivers handles this automatically"
fi

# Ensure NVIDIA modules load at boot (out-of-tree, can't be =y)
if ! grep -q 'nvidia nvidia-modeset nvidia-drm' /etc/conf.d/modules 2>/dev/null; then
    step "Configuring NVIDIA module loading at boot"
    cat >> /etc/conf.d/modules << 'MODEOF'

# NVIDIA GPU (out-of-tree proprietary — must be modules, load early for Xorg)
modules="nvidia nvidia-modeset nvidia-drm nvidia-uvm"
module_nvidia_drm_args="modeset=1"
MODEOF
    ok
else
    step "NVIDIA module loading already configured"; ok
fi

# Ensure nvidia-drm.modeset=1 in GRUB cmdline
if ! grep -q 'nvidia-drm.modeset=1' /etc/default/grub 2>/dev/null; then
    step "Adding nvidia-drm.modeset=1 to GRUB cmdline"
    sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 nvidia-drm.modeset=1"/' /etc/default/grub
    ok
else
    step "nvidia-drm.modeset=1 already in GRUB cmdline"; ok
fi

# ---- Phase 1: System packages ----
step "Syncing librewolf overlay"
if emaint sync -r librewolf 2>/dev/null; then
    emerge_pkg www-client/librewolf-bin
else
    warn "librewolf overlay not configured — skipping"
fi

step "Installing system packages"
sophie_emerge \
    net-libs/nodejs \
    dev-util/bpftool \
    dev-debug/bpftrace \
    dev-util/bcc

step "Verifying Node.js"
node --version && ok || fail "Node.js not working"
npm --version  && ok || warn "npm not available"

# ---- Phase 2: GitHub auth ----
step "Authenticating with GitHub"
if command -v gh &>/dev/null; then
    if su - "${OPERATOR_USER}" -c "gh auth status" &>/dev/null; then
        step "Already authenticated with gh"; ok
    else
        warn "You need to authenticate with GitHub."
        warn "Choose HTTPS + browser/token when prompted."
        su - "${OPERATOR_USER}" -c "gh auth login -h github.com -p https" || warn "gh auth login failed or skipped"
    fi
else
    warn "gh not installed — install manually: https://github.com/cli/cli/releases"
fi

# ---- Phase 3: Clone repos ----
step "Cloning project repositories"
mkdir -p "$PROJECTS_DIR"

# Add your repositories here as [directory]="owner/repo"
declare -A REPOS=(
    # [my-project]="my-org/my-project"
)

for dir in "${!REPOS[@]}"; do
    target="${PROJECTS_DIR}/${dir}"
    if [ -d "${target}/.git" ]; then
        step "  ${dir} — already cloned, pulling latest"
        su - "${OPERATOR_USER}" -c "git -C '${target}' pull --ff-only" 2>/dev/null \
            && ok || warn "  ${dir} pull failed (check branch state)"
    else
        step "  Cloning ${dir}"
        if command -v gh &>/dev/null; then
            su - "${OPERATOR_USER}" -c "gh repo clone '${REPOS[$dir]}' '${target}' -- --recurse-submodules" \
                && ok || warn "  Failed to clone ${dir}"
        else
            su - "${OPERATOR_USER}" -c "git clone --recurse-submodules 'https://github.com/${REPOS[$dir]}.git' '${target}'" \
                && ok || warn "  Failed to clone ${dir}"
        fi
    fi
done

# ---- Phase 4: Dev tools ----
step "Installing Claude Code"
if su - "${OPERATOR_USER}" -c "npx @anthropic-ai/claude-code@latest --version" 2>&1; then
    ok
else
    warn "Claude Code install/check failed — ensure Node.js is working"
fi

# ---- Phase 5: API Key ----
BASHRC="/home/${OPERATOR_USER}/.bashrc"
if grep -q 'ANTHROPIC_API_KEY' "$BASHRC" 2>/dev/null; then
    step "ANTHROPIC_API_KEY already in .bashrc"; ok
else
    warn "Set your Anthropic API key:"
    echo -e "  ${YEL}echo 'export ANTHROPIC_API_KEY=\"sk-ant-...\"' >> ~/.bashrc${NC}"
    echo -e "  ${YEL}source ~/.bashrc${NC}"
fi

# ---- Phase 6: Fix ownership ----
step "Fixing ownership on ${PROJECTS_DIR}"
chown -R "${OPERATOR_USER}:${OPERATOR_USER}" "${PROJECTS_DIR}"
ok

# ---- Summary ----
echo ""
step "=============================="
step "  Run complete"
step "  PASS: ${PASS}  WARN: ${WARN}  FAIL: ${FAIL}"
step "=============================="

if [[ $FAIL -gt 0 ]]; then
    echo -e "\n  ${RED}${FAIL} step(s) failed — review log: ${LOGFILE}${NC}"
fi

echo ""
echo "  Remaining manual steps:"
echo "    1. Set ANTHROPIC_API_KEY in ~/.bashrc (if not done above)"
echo "    2. source ~/.bashrc"
echo "    3. cd ~/projects && claude"
echo ""
echo "  Verification:"
echo "    nvidia-smi"
echo "    node --version"
echo "    bpftool prog list"
echo "    startx  (should launch bspwm desktop)"
echo ""
