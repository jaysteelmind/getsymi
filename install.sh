#!/usr/bin/env bash
# Symi installer — macOS / Linux / WSL
# Usage: curl -fsSL https://jaysteelmind.github.io/getsymi/install.sh | bash
# Docs:  https://docs.symi.ai/install/installer
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INSTALL_METHOD="${SYMI_INSTALL_METHOD:-npm}"
VERSION="${SYMI_VERSION:-latest}"
USE_BETA="${SYMI_BETA:-0}"
GIT_DIR="${SYMI_GIT_DIR:-$HOME/symi}"
GIT_UPDATE="${SYMI_GIT_UPDATE:-1}"
NO_PROMPT="${SYMI_NO_PROMPT:-0}"
NO_ONBOARD="${SYMI_NO_ONBOARD:-0}"
DO_ONBOARD=""
DRY_RUN="${SYMI_DRY_RUN:-0}"
VERBOSE="${SYMI_VERBOSE:-0}"
NPM_LOGLEVEL="${SYMI_NPM_LOGLEVEL:-warn}"
export SHARP_IGNORE_GLOBAL_LIBVIPS="${SHARP_IGNORE_GLOBAL_LIBVIPS:-1}"

NODE_MIN=22
SCRIPT_NAME="install.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }
dry()   { if [ "$DRY_RUN" = "1" ]; then info "[dry-run] $*"; else "$@"; fi; }

has() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if has sudo; then echo "sudo"; else die "Root required but sudo not found."; fi
  fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Symi installer (macOS / Linux / WSL)

USAGE
  curl -fsSL https://jaysteelmind.github.io/getsymi/install.sh | bash
  curl -fsSL https://jaysteelmind.github.io/getsymi/install.sh | bash -s -- [FLAGS]

FLAGS
  --install-method npm|git  Install method (default: npm). Aliases: --method
  --npm                     Shortcut for --install-method npm
  --git                     Shortcut for --install-method git. Alias: --github
  --version <ver|tag>       npm version or dist-tag (default: latest)
  --beta                    Use beta dist-tag if available, else latest
  --git-dir <path>          Clone directory (default: ~/symi). Alias: --dir
  --no-git-update           Skip git pull on existing checkout
  --no-prompt               Disable interactive prompts
  --no-onboard              Skip onboarding after install
  --onboard                 Force onboarding after install
  --dry-run                 Print actions without executing
  --verbose                 Enable debug output
  -h, --help                Show this help

ENVIRONMENT VARIABLES
  SYMI_INSTALL_METHOD       git|npm
  SYMI_VERSION              npm version or dist-tag
  SYMI_BETA                 1 to prefer beta
  SYMI_GIT_DIR              Clone directory
  SYMI_GIT_UPDATE           0 to skip git pull
  SYMI_NO_PROMPT            1 to disable prompts
  SYMI_NO_ONBOARD           1 to skip onboarding
  SYMI_DRY_RUN              1 for dry-run mode
  SYMI_VERBOSE              1 for debug output
  SYMI_NPM_LOGLEVEL         npm log level (error|warn|notice)
  SHARP_IGNORE_GLOBAL_LIBVIPS  0|1 (default 1)
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --install-method|--method) INSTALL_METHOD="$2"; shift 2 ;;
    --npm)         INSTALL_METHOD=npm; shift ;;
    --git|--github) INSTALL_METHOD=git; shift ;;
    --version)     VERSION="$2"; shift 2 ;;
    --beta)        USE_BETA=1; shift ;;
    --git-dir|--dir) GIT_DIR="$2"; shift 2 ;;
    --no-git-update) GIT_UPDATE=0; shift ;;
    --no-prompt)   NO_PROMPT=1; shift ;;
    --no-onboard)  NO_ONBOARD=1; shift ;;
    --onboard)     DO_ONBOARD=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --verbose)     VERBOSE=1; shift ;;
    -h|--help)     usage ;;
    *) die "Unknown flag: $1. Run with --help for usage." ;;
  esac
done

if [ "$VERBOSE" = "1" ]; then set -x; NPM_LOGLEVEL=notice; fi

# Validate install method
case "$INSTALL_METHOD" in
  npm|git) ;;
  *) die "Invalid install method '$INSTALL_METHOD'. Must be npm or git."; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Step 1 — Detect OS
# ---------------------------------------------------------------------------
detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      die "Unsupported OS: $uname_s" ;;
  esac
  ARCH="$(uname -m)"
  info "Detected OS=$OS ARCH=$ARCH"
}

# ---------------------------------------------------------------------------
# Step 2 — Source checkout detection
# ---------------------------------------------------------------------------
detect_checkout() {
  if [ -f "package.json" ] && [ -f "pnpm-workspace.yaml" ]; then
    local pkg_name
    pkg_name="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' package.json | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    if [ "$pkg_name" = "symi" ] || [ "$pkg_name" = "@symi/symi" ]; then
      if [ -t 0 ] && [ "$NO_PROMPT" != "1" ]; then
        warn "Running inside a Symi source checkout."
        printf "Install from this checkout (git) or global npm? [git/npm]: "
        read -r choice
        case "$choice" in
          git) INSTALL_METHOD=git; GIT_DIR="$(pwd)" ;;
          npm) INSTALL_METHOD=npm ;;
          *)   err "Invalid choice: $choice"; exit 2 ;;
        esac
      else
        warn "Inside Symi checkout but no TTY — defaulting to npm method."
        INSTALL_METHOD=npm
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 3 — Install Homebrew (macOS only)
# ---------------------------------------------------------------------------
ensure_homebrew() {
  if [ "$OS" != "macos" ]; then return; fi
  if has brew; then return; fi
  info "Installing Homebrew..."
  dry /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # shellcheck disable=SC2016
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# ---------------------------------------------------------------------------
# Step 4 — Ensure Node.js 22+
# ---------------------------------------------------------------------------
node_version_ok() {
  has node || return 1
  local ver
  ver="$(node --version 2>/dev/null | sed 's/^v//')"
  local major="${ver%%.*}"
  [ "$major" -ge "$NODE_MIN" ] 2>/dev/null
}

ensure_node() {
  if node_version_ok; then
    info "Node $(node --version) found — OK"
    return
  fi

  info "Node.js $NODE_MIN+ required — installing..."

  if [ "$OS" = "macos" ]; then
    ensure_homebrew
    dry brew install node@22
    dry brew link --overwrite node@22 2>/dev/null || true
  else
    # Linux — try NodeSource
    local sudo_cmd
    sudo_cmd="$(need_root)"
    if has apt-get; then
      info "Installing Node via NodeSource (apt)..."
      dry $sudo_cmd bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
      dry $sudo_cmd apt-get install -y nodejs
    elif has dnf; then
      info "Installing Node via NodeSource (dnf)..."
      dry $sudo_cmd bash -c 'curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -'
      dry $sudo_cmd dnf install -y nodejs
    elif has yum; then
      info "Installing Node via NodeSource (yum)..."
      dry $sudo_cmd bash -c 'curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -'
      dry $sudo_cmd yum install -y nodejs
    else
      die "Cannot install Node automatically — no supported package manager found. Install Node $NODE_MIN+ manually."
    fi
  fi

  node_version_ok || die "Node installation succeeded but version check failed."
  info "Node $(node --version) installed"
}

# ---------------------------------------------------------------------------
# Step 5 — Ensure Git
# ---------------------------------------------------------------------------
ensure_git() {
  if has git; then return; fi
  info "Installing Git..."
  if [ "$OS" = "macos" ]; then
    ensure_homebrew
    dry brew install git
  else
    local sudo_cmd
    sudo_cmd="$(need_root)"
    if has apt-get; then
      dry $sudo_cmd apt-get update -y
      dry $sudo_cmd apt-get install -y git
    elif has dnf; then
      dry $sudo_cmd dnf install -y git
    elif has yum; then
      dry $sudo_cmd yum install -y git
    else
      die "Cannot install Git automatically. Install Git manually."
    fi
  fi
  has git || die "Git installation failed."
  info "Git $(git --version) installed"
}

# ---------------------------------------------------------------------------
# Step 6 — Fix npm prefix on Linux if needed
# ---------------------------------------------------------------------------
fix_npm_prefix() {
  [ "$OS" = "linux" ] || return 0
  local prefix
  prefix="$(npm config get prefix 2>/dev/null || echo "")"
  if [ -n "$prefix" ] && [ -w "$prefix/lib" ] 2>/dev/null; then return 0; fi
  if [ "$(id -u)" -eq 0 ]; then return 0; fi

  local new_prefix="$HOME/.npm-global"
  info "npm prefix not writable — switching to $new_prefix"
  mkdir -p "$new_prefix"
  dry npm config set prefix "$new_prefix"

  local bin_dir="$new_prefix/bin"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && ! grep -q "$bin_dir" "$rc" 2>/dev/null; then
      echo "export PATH=\"$bin_dir:\$PATH\"" >> "$rc"
    fi
  done
  export PATH="$bin_dir:$PATH"
}

# ---------------------------------------------------------------------------
# Step 7 — Install Symi
# ---------------------------------------------------------------------------
install_npm() {
  local tag="$VERSION"
  if [ "$USE_BETA" = "1" ]; then
    local beta_ver
    beta_ver="$(npm view symi@beta version 2>/dev/null || echo "")"
    if [ -n "$beta_ver" ]; then
      tag="beta"
      info "Beta available: $beta_ver"
    else
      warn "No beta release found — falling back to $tag"
    fi
  fi

  fix_npm_prefix
  info "Installing symi@$tag via npm..."
  dry npm install -g "symi@$tag" --loglevel="$NPM_LOGLEVEL"
}

install_git() {
  info "Installing Symi from source into $GIT_DIR..."
  if [ -d "$GIT_DIR/.git" ]; then
    if [ "$GIT_UPDATE" = "1" ]; then
      info "Updating existing checkout..."
      dry git -C "$GIT_DIR" pull --ff-only
    else
      info "Skipping git pull (--no-git-update)"
    fi
  else
    dry git clone https://github.com/symi/symi.git "$GIT_DIR"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] Would build and link symi from $GIT_DIR"
    return
  fi

  cd "$GIT_DIR"

  # Ensure pnpm
  if ! has pnpm; then
    info "Installing pnpm..."
    npm install -g pnpm
  fi

  pnpm install
  pnpm run ui:build 2>/dev/null || true
  pnpm run build

  # Create wrapper script
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/symi" <<WRAPPER
#!/usr/bin/env bash
exec node "$GIT_DIR/dist/index.js" "\$@"
WRAPPER
  chmod +x "$HOME/.local/bin/symi"

  # Ensure ~/.local/bin in PATH
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
    fi
  done
  export PATH="$HOME/.local/bin:$PATH"

  info "Symi installed to $HOME/.local/bin/symi"
}

install_symi() {
  case "$INSTALL_METHOD" in
    npm) install_npm ;;
    git) install_git ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 8 — Post-install
# ---------------------------------------------------------------------------
post_install() {
  if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] Would run post-install checks"
    return
  fi

  # Verify install
  if ! has symi; then
    warn "symi not found in PATH. You may need to open a new terminal."
    warn "Run: npm config get prefix  — then add <prefix>/bin to your PATH."
    return
  fi

  info "Running symi doctor..."
  symi doctor --non-interactive || true

  # Onboarding
  if [ "$NO_ONBOARD" = "1" ]; then
    info "Skipping onboarding (--no-onboard)"
  elif [ "$DO_ONBOARD" = "1" ] || { [ -t 0 ] && [ "$NO_PROMPT" != "1" ]; }; then
    info "Starting onboarding..."
    symi onboard --install-daemon || true
  else
    info "No TTY — skipping onboarding. Run 'symi onboard' later."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "Symi $SCRIPT_NAME — install method=$INSTALL_METHOD version=$VERSION"
  detect_os
  detect_checkout
  ensure_node
  ensure_git
  install_symi
  post_install
  info "Done! Run 'symi' to get started."
}

main
