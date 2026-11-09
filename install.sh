#!/bin/bash
# Fail2Ban-Scripts automatic installer
# Installs the scripts into a fail2ban data directory with config.local setup
# Supporta path personalizzato via parametro --dest o variabile d'ambiente FAIL2BAN_DATA_DIR
set -euo pipefail

REPO="spupuz/fail2ban-scripts"

# Parse --dest parameter for custom installation path
DEST_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST_DIR="${2:?--dest requires a path}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Determine installation directory: --dest overrides FAIL2BAN_DATA_DIR default
if [[ -n "$DEST_DIR" ]]; then
  INSTALL_DIR="$(cd "$DEST_DIR" 2>/dev/null && pwd)"/fail2ban-scripts
else
  INSTALL_DIR="${FAIL2BAN_DATA_DIR:-/data}/fail2ban-scripts"
fi

echo "📦 Fail2Ban-Scripts installer"
echo "=============================="

# Create installation directory
mkdir -p "$INSTALL_DIR/scripts"
cd "$INSTALL_DIR"

# Download and extract the latest release
LATEST_TAG=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" |
  grep -oP '"tag_name": "\K[^"]+' || echo "v0.0.1")
echo "  Latest version: $LATEST_TAG"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Download the release archive
curl -sSL "https://github.com/$REPO/archive/$LATEST_TAG.tar.gz" -o "$TMP_DIR/fail2ban-scripts.tar.gz"

# Extract scripts (only the scripts directory and VERSION)
mkdir -p "$TMP_DIR/fail2ban-scripts-root"
tar -xzf "$TMP_DIR/fail2ban-scripts.tar.gz" -C "$TMP_DIR/fail2ban-scripts-root"

# Copy scripts to installation directory
cp -r "$TMP_DIR/fail2ban-scripts-root/fail2ban-scripts-$LATEST_TAG/scripts/"* scripts/
cp "$TMP_DIR/fail2ban-scripts-root/fail2ban-scripts-$LATEST_TAG/VERSION" .

# Set executable permissions
chmod +x scripts/*.sh

# Setup config.local from example if it doesn't exist
CONFIG_LOCAL="$INSTALL_DIR/config.local"
if [[ ! -f "$CONFIG_LOCAL" ]]; then
  echo "  Creating config.local from example..."
  cp config.local.example "$CONFIG_LOCAL"
  chmod 600 "$CONFIG_LOCAL"
  echo "  ⚠️  Remember to edit $CONFIG_LOCAL with your real secrets!"
fi

echo ""
echo "✅ Installation complete!"
echo "  Directory: $INSTALL_DIR"
echo ""
if [[ -n "$DEST_DIR" ]]; then
  echo "ℹ️  Installed at custom path: $DEST_DIR"
  echo "   Auto-updates will use this directory with: scripts/version_check.sh --dest $DEST_DIR"
fi
cat_nl() { printf '\n%s\n' "$1"; }
cat_nl ""
cat_nl "Next steps:"
cat_nl "  1. Edit $CONFIG_LOCAL with your Telegram bot tokens and chat IDs"
cat_nl "  2. Configure ALLOWED_DOMAINS/ALLOWED_HOSTS as needed"
cat_nl "  3. Verify auto-update: scripts/version_check.sh --dest $INSTALL_DIR"
cat_nl "  4. Reload fail2ban: fail2ban-client reload"