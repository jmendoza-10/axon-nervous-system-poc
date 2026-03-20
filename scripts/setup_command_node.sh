#!/usr/bin/env bash
# Setup Raspberry Pi #1 as the command node
set -euo pipefail

REPO_URL="https://github.com/jmendoza-10/axon-nervous-system-poc.git"
PROJECT_DIR="$HOME/axon-nervous-system"

echo "=== Axon Nervous System - Command Node Setup ==="

# Clone or update repo
if [ -d "$PROJECT_DIR/.git" ]; then
    cd "$PROJECT_DIR" && git pull
else
    git clone "$REPO_URL" "$PROJECT_DIR"
fi

cd "$PROJECT_DIR"

# Create Python virtual environment
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install --upgrade pip
pip install -r pi/command_node/requirements.txt

# Install Reticulum
pip install rns

# Configure Reticulum as TCP hub
mkdir -p "$HOME/.reticulum"
if [ ! -f "$HOME/.reticulum/config" ]; then
    rnsd &
    sleep 2
    kill %1 2>/dev/null || true
fi

# Add TCP server interface if not already present
if ! grep -q "TCPServerInterface" "$HOME/.reticulum/config" 2>/dev/null; then
    cat >> "$HOME/.reticulum/config" <<'RNSEOF'

# Axon command node - TCP hub for room nodes
[[Axon TCP Hub]]
  type = TCPServerInterface
  listen_ip = 0.0.0.0
  listen_port = 4242
RNSEOF
    echo "Added TCP hub interface to Reticulum config (port 4242)"
fi

# Create evidence store directory
mkdir -p "$PROJECT_DIR/evidence_store"

# Create systemd service for dashboard
sudo tee /etc/systemd/system/axon-dashboard.service > /dev/null <<EOF
[Unit]
Description=Axon Nervous System Dashboard
After=network.target mosquitto.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR/pi/command_node
ExecStart=$PROJECT_DIR/venv/bin/python dashboard.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for Reticulum daemon
sudo tee /etc/systemd/system/axon-rnsd.service > /dev/null <<EOF
[Unit]
Description=Axon Reticulum Daemon (Hub)
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$PROJECT_DIR/venv/bin/rnsd
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable axon-dashboard axon-rnsd
sudo systemctl start axon-rnsd axon-dashboard

echo ""
echo "=== Command node setup complete ==="
echo "Services running:"
echo "  - axon-rnsd (Reticulum hub on :4242)"
echo "  - axon-dashboard (Web UI on :5000)"
echo ""
echo "Dashboard: http://$(hostname -I | awk '{print $1}'):5000"
echo "Check status: sudo systemctl status axon-dashboard"
echo "View logs:    journalctl -u axon-dashboard -f"
