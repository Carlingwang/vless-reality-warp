#!/bin/bash
# ============================================================
# Web Panel 安装脚本
# 用法: bash install.sh <用户名> <密码>
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$#" -lt 2 ]; then
    echo "用法: bash install.sh <用户名> <密码>"
    echo "示例: bash install.sh admin MySecurePass123"
    exit 1
fi

PANEL_USER="$1"
PANEL_PASS="$2"
PANEL_PORT=8080
PANEL_DIR="/opt/proxy-panel"

echo -e "${CYAN}=== Installing Web Panel ===${NC}"

# Install dependencies
echo "Installing Python3 and Flask..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv

# Create directory
mkdir -p "$PANEL_DIR/templates" "$PANEL_DIR/static"

# Copy files
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/app.py" "$PANEL_DIR/"
cp "$SCRIPT_DIR/templates/"*.html "$PANEL_DIR/templates/"
cp "$SCRIPT_DIR/static/"*.css "$PANEL_DIR/static/"

# Create virtual environment and install packages
cd "$PANEL_DIR"
python3 -m venv venv
./venv/bin/pip install -q flask werkzeug

# Generate password hash
HASHED_PASS=$("$PANEL_DIR/venv/bin/python3" -c "
from werkzeug.security import generate_password_hash
print(generate_password_hash('$PANEL_PASS'))
")

# Write config
cat > "$PANEL_DIR/config.json" << EOF
{
    "username": "$PANEL_USER",
    "password_hash": "$HASHED_PASS",
    "port": $PANEL_PORT
}
EOF

# Create systemd service
cat > /etc/systemd/system/proxy-panel.service << EOF
[Unit]
Description=Proxy Panel Web UI
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=$PANEL_DIR
ExecStart=$PANEL_DIR/venv/bin/python3 $PANEL_DIR/app.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
systemctl daemon-reload
systemctl enable proxy-panel
systemctl restart proxy-panel
sleep 2

# Verify
if systemctl is-active --quiet proxy-panel; then
    echo ""
    echo -e "${GREEN}=== Web Panel Installed Successfully ===${NC}"
    echo ""
    echo "URL:      http://$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP'):$PANEL_PORT"
    echo "Username: $PANEL_USER"
    echo "Password: $PANEL_PASS"
    echo ""
    echo "Service:  systemctl status proxy-panel"
    echo "Logs:     journalctl -u proxy-panel -f"
    echo ""
else
    echo -e "${RED}Failed to start panel. Check: journalctl -u proxy-panel${NC}"
    exit 1
fi
