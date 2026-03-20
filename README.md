# Axon Nervous System - POC

WiFi CSI (Channel State Information) based presence and motion sensing using ESP32-S3 boards and Raspberry Pis, connected over a Reticulum encrypted mesh network.

## Architecture

```
┌─────────────────────────────────────────────┐
│           Pi #1 — COMMAND NODE              │
│  • Reticulum TCP hub (:4242)                │
│  • Web dashboard (:5000)                    │
│  • Evidence chain logger (SHA-256 signed)   │
└───────────────┬─────────────────────────────┘
                │ WiFi / Ethernet
       ┌────────┴────────┐
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│  Pi #2      │   │  Pi #3      │
│  Room A     │   │  Room B     │
│  Reticulum  │   │  Reticulum  │
│  + MQTT     │   │  + MQTT     │
│  + CSI proc │   │  + CSI proc │
└──────┬──────┘   └──────┬──────┘
       │                 │
  ┌────┴────┐       ┌────┴────┐
  │ESP32-TX │       │ESP32-TX │
  │ESP32-RX │       │ESP32-RX │
  └─────────┘       └─────────┘
```

**Data flow:** ESP32-TX blasts probe packets → ESP32-RX captures CSI → UDP JSON to Pi → presence/motion detection → MQTT → Reticulum mesh → Command dashboard

## Hardware

| Component | Qty | Purpose |
|-----------|-----|---------|
| Raspberry Pi 4 (2GB+) | 3 | Mesh nodes + command |
| ESP32-S3 dev boards | 4 | CSI TX/RX pairs (2 per room) |
| MicroSD cards (32GB) | 3 | Pi OS |
| USB-C power supplies | 3+ | Pi + ESP32 power |

## Quick Start

### 1. Flash ESP32s (from your dev machine)

Requires [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/) installed.

```bash
# Source ESP-IDF
. $IDF_PATH/export.sh

# Flash transmitter
./scripts/flash_esp32.sh tx /dev/ttyACM0

# Flash receiver (plug in second board)
./scripts/flash_esp32.sh rx /dev/ttyACM0
```

### 2. Setup Raspberry Pis

SSH into each Pi and run:

```bash
# On ALL Pis - common dependencies
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_pi_common.sh | bash

# On Pi #1 - Command node
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_command_node.sh | bash

# On Pi #2 - Room A node
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_room_node.sh | bash -s room_a

# On Pi #3 - Room B node
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_room_node.sh | bash -s room_b
```

### 3. Configure Reticulum Peers

On Pi #2 and Pi #3, edit `~/.reticulum/config` to add the command node:

```ini
[[Command Node]]
  type = TCPClientInterface
  target_host = <PI_1_IP_ADDRESS>
  target_port = 4242
```

Then restart: `sudo systemctl restart axon-reticulum-bridge`

### 4. Open Dashboard

Navigate to `http://<PI_1_IP>:5000` in your browser.

## Project Structure

```
├── esp32/
│   ├── csi_tx/          # ESP32 transmitter firmware (ESP-IDF)
│   ├── csi_rx/          # ESP32 receiver firmware (ESP-IDF)
│   └── common/          # Shared ESP32 components
├── pi/
│   ├── room_node/       # Room node software (Pi #2, #3)
│   │   ├── csi_processor.py      # UDP→MQTT CSI processing + detection
│   │   └── reticulum_bridge.py   # MQTT→Reticulum forwarding
│   └── command_node/    # Command node software (Pi #1)
│       ├── dashboard.py           # Flask + SocketIO dashboard
│       └── templates/index.html   # Live web UI
└── scripts/
    ├── setup_pi_common.sh     # Base Pi setup
    ├── setup_room_node.sh     # Room node setup + systemd
    ├── setup_command_node.sh  # Command node setup + systemd
    └── flash_esp32.sh         # ESP32 build + flash helper
```

## Phased Roadmap

- **Phase 1** (current): Active CSI sensing with dedicated ESP32 TX/RX pairs
- **Phase 2**: Passive sniffer mode — single ESP32 monitors existing WiFi traffic
- **Phase 3**: OpenWrt router CSI extraction — zero additional hardware

## Key Technologies

- **ESP-IDF** + `esp_wifi_set_csi()` — hardware CSI extraction
- **Reticulum** — encrypted, delay-tolerant mesh networking
- **MQTT (Mosquitto)** — lightweight pub/sub for sensor data
- **Flask + Socket.IO** — real-time web dashboard
- **SHA-256 hash chain** — tamper-evident evidence logging
