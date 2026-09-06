#!/bin/bash
# AIDO (PromptLix assistant) installer script
# Installs the web assistant: local server + web UI + desktop webview.

set -e

INSTALL_DIR="/opt/promptlix"
ASSETS_DIR="$INSTALL_DIR/assets"
WEB_DIR="$INSTALL_DIR/web"
DESKTOP_DIR="/usr/share/applications"
BIN_DIR="/usr/local/bin"

echo "Installing AIDO (the PromptLix assistant)..."

# Create directories
mkdir -p "$INSTALL_DIR" "$ASSETS_DIR" "$WEB_DIR" "$DESKTOP_DIR" "$BIN_DIR"

# Copy files
cp promptlix-server.py "$INSTALL_DIR/"
cp promptlix-webview.py "$INSTALL_DIR/"
cp promptlix_windowd.py "$INSTALL_DIR/"
cp system_prompt.txt "$INSTALL_DIR/"
cp -r web/* "$WEB_DIR/"
cp promptlix.desktop "$DESKTOP_DIR/"
cp -r assets/* "$ASSETS_DIR/" 2>/dev/null || true

# CLI wrapper
cat > "$BIN_DIR/promptlix" << 'WRAP'
#!/bin/bash
exec python3 /opt/promptlix/promptlix-webview.py "$@"
WRAP
chmod +x "$BIN_DIR/promptlix"

# Python dependencies
pip3 install -r requirements.txt 2>/dev/null || \
    (apt-get install -y python3-pip && pip3 install -r requirements.txt)

echo "AIDO (PromptLix assistant) installed to $INSTALL_DIR"
echo "  Launch with: promptlix"
echo "  Server: http://127.0.0.1:18437 (hidden port, token-protected)"
