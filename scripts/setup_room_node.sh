#!/usr/bin/env bash
# Setup a Raspberry Pi as a room node (Pi #2 or Pi #3)
set -euo pipefail

ROOM_ID="${1:-room_a}"
REPO_URL="https://github.com/jmendoza-10/axon-nervous-system-poc.git"
PROJECT_DIR="$HOME/axon-nervous-system"

echo "=== Axon Nervous System - Room Node Setup (${ROOM_ID}) ==="

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
pip install -r pi/room_node/requirements.txt

# Install Reticulum
pip install rns

# Configure Reticulum
mkdir -p "$HOME/.reticulum"
if [ ! -f "$HOME/.reticulum/config" ]; then
    rnsd &
    sleep 2
    kill %1 2>/dev/null || true
    echo "Default Reticulum config generated at ~/.reticulum/config"
    echo "Edit it to add the command node as a TCP peer."
fi

# Create systemd services
sudo tee /etc/systemd/system/axon-csi-processor.service > /dev/null <<EOF
[Unit]
Description=Axon CSI Processor (${ROOM_ID})
After=network.target mosquitto.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
Environment=ROOM_ID=${ROOM_ID}
ExecStart=$PROJECT_DIR/venv/bin/python pi/room_node/csi_processor.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/axon-reticulum-bridge.service > /dev/null <<EOF
[Unit]
Description=Axon Reticulum Bridge (${ROOM_ID})
After=network.target mosquitto.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
Environment=ROOM_ID=${ROOM_ID}
ExecStart=$PROJECT_DIR/venv/bin/python pi/room_node/reticulum_bridge.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable axon-csi-processor axon-reticulum-bridge
sudo systemctl start axon-csi-processor axon-reticulum-bridge

echo ""
echo "=== Room node '${ROOM_ID}' setup complete ==="
echo "Services running:"
echo "  - axon-csi-processor (UDP :5500 → MQTT)"
echo "  - axon-reticulum-bridge (MQTT → Reticulum mesh)"
echo ""
echo "Check status: sudo systemctl status axon-csi-processor"
echo "View logs:    journalctl -u axon-csi-processor -f"
