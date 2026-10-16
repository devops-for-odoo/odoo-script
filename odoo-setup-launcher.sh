
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/devops-for-odoo/odoo-script.git"
BRANCH="odoo-scripts"
INSTALL_DIR="/opt/odoo-scripts"

# Ensure root access
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this launcher as root."
    exit 1
fi

# Verify Ubuntu
if [[ ! -f /etc/os-release ]] ||
   ! grep -qi '^ID=ubuntu' /etc/os-release; then
    echo "ERROR: This launcher is intended for Ubuntu."
    exit 1
fi

echo "======================================"
echo "     Universal Odoo Setup Launcher"
echo "======================================"

# Install Git if missing
if ! command -v git >/dev/null 2>&1; then
    echo "Installing Git..."
    apt-get update
    apt-get install -y git
fi

# Clone or update repository
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "Updating Odoo scripts..."
    git -C "$INSTALL_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$INSTALL_DIR" checkout -B "$BRANCH" \
        "origin/$BRANCH"
else
    echo "Downloading Odoo scripts..."
    git clone --depth 1 --branch "$BRANCH" \
        "$REPO_URL" "$INSTALL_DIR"
fi

echo
echo "Select your installation method:"
echo "1) Install a single Odoo version (from odoo13 to odoo20)"
echo "2) Install all supported versions (from odoo14 to odoo20)"
echo "3) Exit"
echo

read -rp "Enter choice [1-3]: " choice

case "$choice" in
    1)
        SCRIPT="New-odoo-install.sh"
        ;;
    2)
        SCRIPT="odoo-install-all-version.sh"
        ;;
    3)
        exit 0
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac

SCRIPT_PATH="$INSTALL_DIR/$SCRIPT"

if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "ERROR: Installer not found: $SCRIPT_PATH"
    exit 1
fi

echo
echo "Starting: $SCRIPT"
echo "Target: $(hostname)"
echo

bash "$SCRIPT_PATH"
