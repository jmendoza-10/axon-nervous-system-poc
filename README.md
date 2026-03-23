# Axon Nervous System - POC

WiFi CSI (Channel State Information) based presence and motion sensing using ESP32-S3 boards and Raspberry Pis. Detection events are forwarded over a Reticulum encrypted mesh and logged to a tamper-evident evidence chain.

## Architecture

```
┌──────────────────────────────────────────────┐
│           Pi #1 — COMMAND NODE               │
│  • Reticulum TCP hub (:4242)                 │
│  • Web dashboard + SocketIO (:5000)          │
│  • Evidence chain logger (SHA-256 chained)   │
└───────────────┬──────────────────────────────┘
                │ Reticulum (encrypted TCP)
       ┌────────┴────────┐
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│  Pi #2      │   │  Pi #3      │
│  Room A     │   │  Room B     │
│  • MQTT     │   │  • MQTT     │
│  • CSI proc │   │  • CSI proc │
│  • RNS brdg │   │  • RNS brdg │
└──────┬──────┘   └──────┬──────┘
       │                 │
  ┌────┴────┐       ┌────┴────┐
  │ESP32-TX │       │ESP32-TX │
  │ESP32-RX │       │ESP32-RX │
  └─────────┘       └─────────┘
```

### Data flow

```
ESP32-TX  →  (WiFi probe packets)  →  ESP32-RX
                                           │ UDP JSON (:5500)
                                           ▼
                                    csi_processor.py
                                    (presence/motion detection)
                                           │ MQTT localhost
                                           ▼
                                    reticulum_bridge.py
                                    (strips heatmap, sends 2 RNS packets)
                                           │ Reticulum E2E encrypted
                                           ▼
                                    dashboard.py (command node)
                                    (on_rns_packet → SocketIO emit)
                                           │ WebSocket
                                           ▼
                                    Browser dashboard
```

### How Reticulum is used

Reticulum is the **inter-Pi transport**, not an MQTT wrapper. MQTT runs only on `localhost` inside each room Pi as IPC between `csi_processor` and `reticulum_bridge` — it never leaves the Pi.

The bridge picks up each detection from local MQTT and sends it as a Reticulum packet to the command node. Reticulum provides **end-to-end encryption automatically**: every packet is encrypted to the destination's X25519 public key (+ AES-128). The command node announces its destination hash (a fingerprint of its public key) every 60 seconds; room bridges receive the announce, store that hash, and use it to encrypt and address all subsequent packets.

Two separate RNS packets are sent per detection:
1. **Detection packet** — presence/motion/variance fields (~200 bytes, fits the 500-byte MTU)
2. **Heatmap packet** — per-subcarrier deviation quantized to 0–15 integers (~220 bytes)

The heatmap must be split out because the full float array would exceed Reticulum's 500-byte MTU.

## Detection Algorithm

### Calibration

On startup the processor waits `CALIBRATION_DELAY=20s` (configurable via env var) before beginning to collect samples, giving time to vacate the room. It then collects 200 samples (~2s) to compute a per-subcarrier baseline from the empty room. Detection only begins after calibration completes.

If the ESP32 reconnects and changes the subcarrier count, calibration resets automatically.

### Presence detection

Per-sample deviation from the empty-room baseline is computed across all 64 subcarriers. The variance of that deviation vector is compared against `PRESENCE_THRESHOLD=8.0`. A 10-second **leave confirmation** timer prevents false empties: once presence is detected, the room must show no presence for 10 consecutive seconds before being declared empty.

### Motion detection

Motion uses the **temporal variance** over the last 5 samples (~50ms at 100Hz) — the mean per-subcarrier variance across those frames. This measures frame-to-frame change rate directly, making it responsive to actual movement without being confused by static presence (someone standing still). Threshold: `MOTION_THRESHOLD=3.0`.

### Heatmap / spectrogram

Each detection payload includes a 64-element array of per-subcarrier absolute deviations from baseline. The dashboard accumulates 60 rows of these (60 seconds) and renders them as a scrolling spectrogram: time flows upward, columns are subcarriers 1–64, color encodes deviation magnitude (dark blue = low, red = high, `HEAT_MAX=15.0`).

### Key parameters (csi_processor.py)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `WINDOW_SIZE` | 500 | Sliding window for baseline comparison (~5s) |
| `PRESENCE_THRESHOLD` | 8.0 | Variance above baseline to declare presence |
| `MOTION_THRESHOLD` | 3.0 | Temporal variance threshold for motion |
| `MOTION_WINDOW` | 5 | Samples for motion measurement (~50ms) |
| `BREATHING_WINDOW` | 400 | Samples for slow temporal variance (~4s) |
| `CALIBRATION_DELAY` | 20 | Seconds before calibration starts |
| `LEAVE_CONFIRM_SECS` | 10.0 | Sustained absence before declaring empty |
| `PUBLISH_INTERVAL` | 1.0 | MQTT publish rate (Hz) |

## Evidence Chain

All detection events are appended to `evidence_store/evidence_chain.jsonl` on the command node. Each record includes:

```json
{
  "seq": 42,
  "timestamp": "2026-03-23T05:07:13.000Z",
  "event": { "room": "room_a", "presence": true, ... },
  "prev_hash": "abc123...",
  "hash": "def456..."
}
```

The hash is `SHA-256(prev_hash + ":" + JSON(event))`, forming a chain where any tampering breaks all subsequent hashes. The dashboard verifies the chain every 10 seconds via `/api/evidence/verify`. The chain survives service restarts — on startup the logger reads the last hash from the file and continues the chain from there.

The deploy script resets the chain (`rm evidence_chain.jsonl`) before each deployment so a fresh baseline produces a valid chain from genesis.

## Hardware

| Component | Qty | Purpose |
|-----------|-----|---------|
| Raspberry Pi 4 or 5 (2GB+) | 3 | Mesh nodes + command |
| ESP32-S3 dev boards | 4 | CSI TX/RX pairs (2 per room) |
| MicroSD cards (32GB) | 3 | Pi OS |
| USB-C power supplies | 3+ | Pi + ESP32 power |

## Quick Start

### 1. Flash ESP32s (from your dev machine)

Requires [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/) installed.

```bash
# Install ESP-IDF (first time only)
mkdir -p ~/workspace/opensource && cd ~/workspace/opensource
git clone --recursive https://github.com/espressif/esp-idf.git
~/workspace/opensource/esp-idf/install.sh esp32s3

# Source ESP-IDF (every new shell session)
. ~/workspace/opensource/esp-idf/export.sh

# Flash transmitter
./scripts/flash_esp32.sh tx /dev/ttyACM0

# Flash receiver (plug in second board)
./scripts/flash_esp32.sh rx /dev/ttyACM0
```

The RX firmware is configured with `lltf_en=true`, `htltf_en=false`, `stbc_htltf2_en=false` to lock the subcarrier count to 64 (L-LTF only). This prevents the subcarrier count from flipping between 64 and 192 mid-session, which would invalidate the baseline and force recalibration.

### 2. Flash Raspberry Pi SD Cards (from your Mac)

Use the included flasher script to prepare SD cards with headless config and auto-setup:

```bash
# Flash the command node SD card (Pi 4)
./scripts/flash_pi_sd.sh \
  --board pi4 \
  --role command \
  --wifi-ssid "YourWiFi" \
  --wifi-pass "YourPassword"

# Flash Room A node (Pi 5)
./scripts/flash_pi_sd.sh \
  --board pi5 \
  --role room \
  --room-id room_a \
  --wifi-ssid "YourWiFi" \
  --wifi-pass "YourPassword"

# Flash Room B node (Pi 5)
./scripts/flash_pi_sd.sh \
  --board pi5 \
  --role room \
  --room-id room_b \
  --wifi-ssid "YourWiFi" \
  --wifi-pass "YourPassword"
```

The script will prompt you to select the SD card and confirm before writing. Default username is `axon` (password prompted).

**Options:**

| Flag | Default | Description |
|------|---------|-------------|
| `--board` | `pi4` | Target board: `pi4` or `pi5` |
| `--role` | `room` | Node role: `command` or `room` |
| `--room-id` | `room_a` | Room identifier (room nodes only) |
| `--hostname` | auto | Pi hostname (auto-set from role/room-id) |
| `--user` | `axon` | Linux username |
| `--password` | prompted | Linux password |
| `--wifi-ssid` | — | WiFi network name |
| `--wifi-pass` | — | WiFi password |
| `--skip-download` | — | Skip image download if already cached |

### 3. Boot & Run First-Boot Setup

After inserting the SD card and powering on the Pi:

```bash
# 1. SSH into the Pi (wait ~60s for first boot)
ssh axon@axon-command.local      # command node
ssh axon@axon-room-a.local       # room A node
ssh axon@axon-room-b.local       # room B node

# 2. Run the first-boot setup script
sudo bash /boot/firmware/axon-firstboot/setup.sh
```

This will automatically:
- Install all system dependencies (Python, MQTT, Git, etc.)
- Clone the Axon repo
- Create a Python venv and install packages
- Configure and start systemd services for the node's role
- Set up Reticulum mesh networking

> **Tip:** Monitor progress with `tail -f /var/log/axon-firstboot.log`

### 4. Manual Setup (Alternative)

If you prefer to set up Pis manually instead of using the flasher:

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

### 5. Open Dashboard

Navigate to `http://axon-command.local:5000` in your browser.

The dashboard shows:
- **Per-room presence/motion badges** with live variance values
- **Scrolling CSI spectrogram** (64 subcarriers × 60s) — watch for the blue→red shift when someone enters
- **Live event log** with hash fingerprints
- **Evidence chain status** (valid record count, or broken-at index if tampered)

## Deploying Updates

```bash
# Deploy to all nodes (resets evidence chain on command node)
bash scripts/deploy.sh all

# Deploy to a single node
bash scripts/deploy.sh command
bash scripts/deploy.sh room-a
bash scripts/deploy.sh room-b
```

After deploying to a room node, the Reticulum bridge restarts and must rediscover the command node via its 60-second periodic announce. Detections will be dropped during this ~60s window. This is expected behavior.

## Systemd Services

| Node | Service | Purpose |
|------|---------|---------|
| Command | `axon-dashboard` | Flask dashboard + Reticulum receiver |
| Command | `axon-rnsd` | Reticulum daemon (TCP hub on :4242) |
| Room | `axon-csi-processor` | UDP → MQTT detection pipeline |
| Room | `axon-reticulum-bridge` | MQTT → Reticulum forwarding |

```bash
# View live logs
journalctl -u axon-dashboard -f
journalctl -u axon-csi-processor -f
journalctl -u axon-reticulum-bridge -f
```

## Project Structure

```
├── esp32/
│   ├── csi_tx/          # ESP32 transmitter firmware (ESP-IDF)
│   └── csi_rx/          # ESP32 receiver firmware (ESP-IDF)
├── pi/
│   ├── room_node/       # Room node software (Pi #2, #3)
│   │   ├── csi_processor.py      # UDP→MQTT CSI processing + detection
│   │   └── reticulum_bridge.py   # MQTT→Reticulum forwarding
│   └── command_node/    # Command node software (Pi #1)
│       ├── dashboard.py           # Flask + SocketIO + Reticulum receiver
│       └── templates/index.html   # Live web UI with spectrogram
└── scripts/
    ├── deploy.sh              # SCP + service restart for all/individual nodes
    ├── flash_pi_sd.sh         # RPi SD card flasher (macOS/Linux)
    ├── setup_pi_common.sh     # Base Pi setup
    ├── setup_room_node.sh     # Room node setup + systemd
    ├── setup_command_node.sh  # Command node setup + systemd
    └── flash_esp32.sh         # ESP32 build + flash helper
```

## Phased Roadmap

- **Phase 1** (current): Active CSI sensing with dedicated ESP32 TX/RX pairs per room
- **Phase 2**: Passive sniffer mode — single ESP32 monitors existing WiFi traffic
- **Phase 3**: OpenWrt router CSI extraction — zero additional hardware

## Key Technologies

- **ESP-IDF** + `esp_wifi_set_csi()` — hardware CSI extraction on ESP32-S3
- **Reticulum** — encrypted, delay-tolerant mesh networking (E2E encryption via X25519 + AES-128)
- **MQTT (Mosquitto)** — local IPC between processes on each room Pi (not exposed on the network)
- **Flask + Socket.IO** — real-time web dashboard with live spectrogram
- **SHA-256 hash chain** — tamper-evident evidence logging with persistence across restarts
