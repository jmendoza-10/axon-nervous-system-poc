#!/usr/bin/env bash
# Common setup for all Raspberry Pis (run on each Pi)
set -euo pipefail

echo "=== Axon Nervous System - Pi Common Setup ==="

# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install system dependencies
sudo apt-get install -y \
    python3-pip \
    python3-venv \
    mosquitto \
    mosquitto-clients \
    git

# Enable and start MQTT broker
sudo systemctl enable mosquitto
sudo systemctl start mosquitto

# Create project directory
PROJECT_DIR="$HOME/axon-nervous-system"
mkdir -p "$PROJECT_DIR"

echo "Common setup complete."
echo "Next: run setup_room_node.sh or setup_command_node.sh"
