#!/usr/bin/env bash
# Symi CLI installer — prefix-local install (no root required)
# Usage: curl -fsSL https://jaysteelmind.github.io/getsymi/install-cli.sh | bash
# Docs:  https://docs.symi.ai/install/installer
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PREFIX="${SYMI_PREFIX:-$HOME/.symi}"
VERSION="${SYMI_VERSION:-latest}"
NODE_VERSION="${SYMI_NODE_VERSION:-22.22.0}"
NO_ONBOARD="${SYMI_NO_ONBOARD:-1}"
DO_ONBOARD=0
JSON_OUTPUT=0
SET_NPM_PREFIX=0
NPM_LOGLEVEL="${SYMI_NPM_LOGLEVEL:-warn}"
LEGACY_GIT_DIR="${SYMI_GIT_DIR:-}"
export SHARP_IGNORE_GLOBAL_LIBVIPS="${SHARP_IGNORE_GLOBAL_LIBVIPS:-1}"

SCRIPT_NAME="install-cli.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { [ "$JSON_OUTPUT" = "1" ] && return; printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
warn()  { [ "$JSON_OUTPUT" = "1" ] && return; printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

emit_json() {
  if [ "$JSON_OUTPUT" = "1" ]; then
    printf '%s\n' "$1"
  fi
}

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
Symi CLI installer — local prefix install

USAGE
  curl -fsSL https://jaysteelmind.github.io/getsymi/install-cli.sh | bash
  curl -fsSL https://jaysteelmind.github.io/getsymi/install-cli.sh | bash -s -- [FLAGS]

FLAGS
  --prefix <path>       Install prefix (default: ~/.symi)
  --version <ver>       Symi version or dist-tag (default: latest)
  --node-version <ver>  Node.js version (default: 22.22.0)
  --json                Emit NDJSON events for automation
  --onboard             Run symi onboard after install
  --no-onboard          Skip onboarding (default)
  --set-npm-prefix      Force npm prefix to ~/.npm-global if not writable
  -h, --help            Show this help

ENVIRONMENT VARIABLES
  SYMI_PREFIX           Install prefix
  SYMI_VERSION          Symi version or dist-tag
  SYMI_NODE_VERSION     Node.js version
  SYMI_NO_ONBOARD       1 to skip onboarding
  SYMI_NPM_LOGLEVEL     npm log level
  SYMI_GIT_DIR          Legacy cleanup lookup path
  SHARP_IGNORE_GLOBAL_LIBVIPS  0|1 (default 1)
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)          PREFIX="$2"; shift 2 ;;
    --version)         VERSION="$2"; shift 2 ;;
    --node-version)    NODE_VERSION="$2"; shift 2 ;;
    --json)            JSON_OUTPUT=1; shift ;;
    --onboard)         DO_ONBOARD=1; NO_ONBOARD=0; shift ;;
    --no-onboard)      NO_ONBOARD=1; DO_ONBOARD=0; shift ;;
    --set-npm-prefix)  SET_NPM_PREFIX=1; shift ;;
    -h|--help)         usage ;;
    *) die "Unknown flag: $1. Run with --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Detect platform
# ---------------------------------------------------------------------------
detect_platform() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "$uname_s" in
    Darwin) PLATFORM_OS="darwin" ;;
    Linux)  PLATFORM_OS="linux" ;;
    *)      die "Unsupported OS: $uname_s" ;;
  esac

  case "$uname_m" in
    x86_64|amd64)   PLATFORM_ARCH="x64" ;;
    aarch64|arm64)   PLATFORM_ARCH="arm64" ;;
    armv7l)          PLATFORM_ARCH="armv7l" ;;
    *)               die "Unsupported architecture: $uname_m" ;;
  esac

  info "Platform: ${PLATFORM_OS}-${PLATFORM_ARCH}"
}

# ---------------------------------------------------------------------------
# Step 1 — Download and install local Node runtime
# ---------------------------------------------------------------------------
install_node() {
  local node_dir="$PREFIX/tools/node-v$NODE_VERSION"
  local node_bin="$node_dir/bin/node"

  if [ -x "$node_bin" ]; then
    info "Node $NODE_VERSION already installed at $node_dir"
    NODE_BIN_DIR="$node_dir/bin"
    return
  fi

  local tarball="node-v${NODE_VERSION}-${PLATFORM_OS}-${PLATFORM_ARCH}.tar.xz"
  local url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  local shasums_url="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"

  info "Downloading Node $NODE_VERSION..."
  emit_json "{\"event\":\"download_node\",\"version\":\"$NODE_VERSION\"}"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  curl -fsSL "$url" -o "$tmpdir/$tarball"
  curl -fsSL "$shasums_url" -o "$tmpdir/SHASUMS256.txt"

  info "Verifying SHA-256..."
  local expected_sha
  expected_sha="$(grep "$tarball" "$tmpdir/SHASUMS256.txt" | awk '{print $1}')"
  if [ -z "$expected_sha" ]; then
    die "Could not find SHA-256 for $tarball in SHASUMS256.txt"
  fi

  local actual_sha
  if has sha256sum; then
    actual_sha="$(sha256sum "$tmpdir/$tarball" | awk '{print $1}')"
  elif has shasum; then
    actual_sha="$(shasum -a 256 "$tmpdir/$tarball" | awk '{print $1}')"
  else
    die "No sha256sum or shasum available for verification."
  fi

  if [ "$expected_sha" != "$actual_sha" ]; then
    die "SHA-256 mismatch! Expected: $expected_sha  Got: $actual_sha"
  fi
  info "SHA-256 verified."

  mkdir -p "$node_dir"
  tar -xf "$tmpdir/$tarball" -C "$node_dir" --strip-components=1
  rm -rf "$tmpdir"
  trap - EXIT

  NODE_BIN_DIR="$node_dir/bin"
  info "Node installed to $node_dir"
  emit_json "{\"event\":\"node_installed\",\"path\":\"$node_dir\"}"
}

# ---------------------------------------------------------------------------
# Step 2 — Ensure Git
# ---------------------------------------------------------------------------
ensure_git() {
  if has git; then return; fi
  info "Installing Git..."

  local uname_s
  uname_s="$(uname -s)"
  if [ "$uname_s" = "Darwin" ]; then
    if has brew; then brew install git; else die "Git not found. Install Xcode Command Line Tools or Homebrew."; fi
  else
    local sudo_cmd
    sudo_cmd="$(need_root)"
    if has apt-get; then
      $sudo_cmd apt-get update -y && $sudo_cmd apt-get install -y git
    elif has dnf; then
      $sudo_cmd dnf install -y git
    elif has yum; then
      $sudo_cmd yum install -y git
    else
      die "Cannot install Git automatically. Install Git manually."
    fi
  fi
  has git || die "Git installation failed."
}

# ---------------------------------------------------------------------------
# Step 3 — Install Symi under prefix
# ---------------------------------------------------------------------------
install_symi() {
  local npm_bin="$NODE_BIN_DIR/npm"
  local npx_bin="$NODE_BIN_DIR/npx"

  info "Installing symi@$VERSION to $PREFIX..."
  emit_json "{\"event\":\"install_symi\",\"version\":\"$VERSION\",\"prefix\":\"$PREFIX\"}"

  export PATH="$NODE_BIN_DIR:$PATH"

  mkdir -p "$PREFIX/bin" "$PREFIX/lib"

  "$npm_bin" install --prefix "$PREFIX" -g "symi@$VERSION" --loglevel="$NPM_LOGLEVEL"

  # Write wrapper script
  local wrapper="$PREFIX/bin/symi"
  cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
export PATH="$NODE_BIN_DIR:\$PATH"
exec "$PREFIX/lib/node_modules/.bin/symi" "\$@"
WRAPPER
  chmod +x "$wrapper"

  info "Symi installed to $wrapper"
  emit_json "{\"event\":\"symi_installed\",\"bin\":\"$wrapper\"}"

  # Ensure prefix bin is in PATH for shell startup
  local bin_dir="$PREFIX/bin"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && ! grep -q "$bin_dir" "$rc" 2>/dev/null; then
      echo "export PATH=\"$bin_dir:\$PATH\"" >> "$rc"
    fi
  done
  export PATH="$bin_dir:$PATH"
}

# ---------------------------------------------------------------------------
# Step 4 — Legacy cleanup
# ---------------------------------------------------------------------------
legacy_cleanup() {
  if [ -n "$LEGACY_GIT_DIR" ] && [ -d "$LEGACY_GIT_DIR/.git" ]; then
    info "Legacy git checkout found at $LEGACY_GIT_DIR (not removed — clean up manually if desired)"
  fi
}

# ---------------------------------------------------------------------------
# Step 5 — Post-install
# ---------------------------------------------------------------------------
post_install() {
  if [ "$DO_ONBOARD" = "1" ]; then
    info "Running onboarding..."
    emit_json "{\"event\":\"onboard_start\"}"
    "$PREFIX/bin/symi" onboard --install-daemon || true
    emit_json "{\"event\":\"onboard_complete\"}"
  fi
  emit_json "{\"event\":\"complete\",\"prefix\":\"$PREFIX\",\"bin\":\"$PREFIX/bin/symi\"}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "Symi $SCRIPT_NAME — prefix=$PREFIX version=$VERSION node=$NODE_VERSION"
  detect_platform
  install_node
  ensure_git
  install_symi
  legacy_cleanup
  post_install
  info "Done! Add $PREFIX/bin to your PATH, then run 'symi'."
}

main
