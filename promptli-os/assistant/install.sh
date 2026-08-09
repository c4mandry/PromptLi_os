#!/bin/bash
# promptLi Assistant installer script

set -e

INSTALL_DIR="/opt/promptli"
ASSETS_DIR="$INSTALL_DIR/assets"
DESKTOP_DIR="/usr/share/applications"
BIN_DIR="/usr/local/bin"

echo "⚡ Installing promptLi Assistant..."

# Create directories
mkdir -p "$INSTALL_DIR" "$ASSETS_DIR" "$DESKTOP_DIR"

# Copy files
cp promptli_assistant.py "$INSTALL_DIR/"
cp promptli_daemon.py "$INSTALL_DIR/"
cp promptli.desktop "$DESKTOP_DIR/"
cp -r assets/* "$ASSETS_DIR/" 2>/dev/null || true

# Symlink to PATH
ln -sf "$INSTALL_DIR/promptli_assistant.py" "$BIN_DIR/promptli"

# Install Python dependencies
pip3 install -r requirements.txt 2>/dev/null || \
    apt-get install -y python3-pip && pip3 install -r requirements.txt

# Set up systemd daemon service (optional)
cat > /etc/systemd/system/promptli-daemon.service << 'SERVICE'
[Unit]
Description=promptLi System Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/promptli/promptli_daemon.py
Restart=on-failure
User=root
Group=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable promptli-daemon.service 2>/dev/null || true

echo "✅ promptLi Assistant installed to $INSTALL_DIR"
echo "   Launch with: promptli"
echo "   Daemon: systemctl start promptli-daemon"
