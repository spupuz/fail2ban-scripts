#!/bin/bash
# Fail2Ban-Scripts automatic installer
# Installs the scripts into a fail2ban data directory with config.local setup
set -euo pipefail

REPO="spupuz/fail2ban-scripts"
INSTALL_DIR="${FAIL2BAN_DATA_DIR:-/data}/fail2ban-scripts"

echo "📦 Fail2Ban-Scripts installer"
echo "=============================="

# Create installation directory
mkdir -p "$INSTALL_DIR/scripts"
cd "$INSTALL_DIR"

# Download and extract the latest release
LATEST_TAG=$(curl -sSL "https://api.github.com/repos/$REPO/releases/latest" |
  grep -oP '"tag_name": "\K[^"]+' || echo "v0.0.1")
echo "  Latest version: $LATEST_TAG"

# Download the release archive
curl -sSL "https://github.com/$REPO/archive/$LATEST_TAG.tar.gz" -o /tmp/fail2ban-scripts.tar.gz

# Extract scripts (only the scripts directory and VERSION)
mkdir -p /tmp/fail2ban-scripts-root
tar -xzf /tmp/fail2ban-scripts.tar.gz -C /tmp/fail2ban-scripts-root

# Copy scripts to installation directory
cp -r /tmp/fail2ban-scripts-root/fail2ban-scripts-$LATEST_TAG/scripts/* scripts/
cp /tmp/fail2ban-scripts-root/fail2ban-scripts-$LATEST_TAG/VERSION .

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

# Cleanup
rm -rf /tmp/fail2ban-scripts-root /tmp/fail2ban-scripts.tar.gz

echo ""
echo "✅ Installation complete!"
echo "  Directory: $INSTALL_DIR"
echo ""
echo "Next steps:"
echo "  1. Edit $CONFIG_LOCAL with your Telegram bot tokens and chat IDs"
echo "  2. Configure ALLOWED_DOMAINS/ALLOWED_HOSTS as needed"
echo "  3. Deploy to your fail2ban data directory:"
echo "     scripts/deploy.sh --apply --dest /path/to/fail2ban/data"
echo "  4. Reload fail2ban: fail2ban-client reload"