# Axon Nervous System

A personal proof of concept for Wi-Fi CSI presence and motion sensing on ESP32-S3. A room node turns Channel State Information from an ESP32-S3 into presence and motion flags. A command node can show those flags on a small dashboard.

![Dashboard presence detection](https://github.com/jmendoza-10/axon-nervous-system-poc/releases/download/v0.1.0/dashboard_presense_detect_compressed.gif)

## Hardware

| Component | Role |
|-----------|------|
| ESP32-S3 dev board (active pair) | One transmitter and one receiver per room |
| ESP32-S3 dev board (passive) | One sniffer per room, no association |
| Raspberry Pi 4 or 5 | Room node (`csi_processor.py`) and, optionally, the command-node dashboard |

Active mode uses a TX/RX pair on the same Wi-Fi network as the room Pi. Passive mode uses one board in promiscuous mode. A laptop serial bridge forwards its UART JSON, because `WIFI_MODE_NULL` has no network association.

## Active and passive modes

Both firmwares lock CSI to the **legacy long training field (L-LTF)**: `lltf_en = true`, `htltf_en = false`, `stbc_htltf2_en = false`. That keeps the capture at **64 subcarriers**. Enabling HT-LTF or STBC would change the count (the STBC path is 192) and force the detector to drop its baseline.

**Active.** `esp32/csi_tx` joins the network as a station and sends a 32-byte UDP broadcast every `CSI_TX_RATE_MS` (10 ms, about 100 Hz) to port 5501. `esp32/csi_rx` joins the same network, computes amplitude `sqrt(I² + Q²)` for each L-LTF subcarrier, and streams one JSON object per packet to the room Pi on UDP port 5500 (`CONFIG_CSI_UDP_TARGET_PORT`).

**Passive.** `esp32/csi_passive` starts in `WIFI_MODE_NULL`, locks to `CONFIG_CSI_CHANNEL`, turns on promiscuous mode, and keeps CSI frames whose source MAC matches `CONFIG_CSI_ANCHOR_MAC`. It prints the same JSON shape on UART. The firmware header describes anchor beacons as a roughly 10 Hz baseline, with extra frames when the AP carries data. `scripts/passive_serial_bridge.py` reads that serial stream and forwards datagrams to the room Pi. The Pi can also drop non-anchor frames by setting `ANCHOR_MAC` to the AP BSSID; an empty `ANCHOR_MAC` accepts every source (active mode).

## Detection algorithm

`pi/room_node/csi_processor.py` keeps a time-based history of amplitude vectors and publishes on MQTT topic `axon/detection` at most once per `PUBLISH_INTERVAL` (1.0 s).

### Windows and thresholds

| Constant | Value | What the code does with it |
|----------|-------|----------------------------|
| `WINDOW_DURATION_SECS` | 30.0 s | Rolling history. Samples older than this are dropped. |
| `MOTION_WINDOW_SECS` | 0.5 s | Frame-to-frame change used for motion. Needs at least 2 samples in the window; otherwise temporal variance is 0. |
| `BREATHING_WINDOW_SECS` | 13.0 s | Slow change published as `breathing_var`. Needs at least 10 samples; otherwise the value is 0. |
| `PRESENCE_THRESHOLD` | 6.0 | Presence when the variance of `(sample − baseline)` exceeds this. |
| `MOTION_THRESHOLD` | 2.5 | Motion when the mean per-subcarrier variance inside the 0.5 s window exceeds this. |
| `BREATHING_THRESHOLD` | 1.5 | Named constant in the processor. Presence and motion decisions use 6.0 and 2.5. `breathing_var` is computed and included in the payload. |
| `MOTION_RATE_GATE_HZ` | 30.0 | Motion is disabled while the estimated sample rate is below 30 Hz. |

The rate estimate is the reciprocal of the mean of the last 20 inter-packet gaps. Gaps of 0 s or of 2.0 s and longer are ignored. A rate of 0.0 (not enough gaps yet) leaves motion enabled. Motion is cleared when `0 < rate < 30`.

The first packet builds a null-subcarrier mask: bins whose amplitude is 0.0 are removed, and later packets reuse that mask. Variance is computed on the bins that remain.

### Calibration

`CALIBRATION_DELAY` is 20 seconds (`CALIBRATION_DELAY` env var overrides it). On startup the process sleeps that long and asks you to leave the room. UDP listening starts after the sleep.

The detector then counts arrivals. While the count is below `CALIBRATION_SAMPLES` (200) it reports `calibrating`. On the 200th sample it sets the baseline to the mean of the amplitude vectors still inside the 30 s window, then reports `calibrated`. At about 10 Hz those 200 samples span about 20 s, so they all sit inside the window. If packets arrive slower than the window can hold, samples older than 30 s are already gone and the mean uses only what remains. The counter still waits for 200 arrivals.

If a later packet has a different subcarrier count, the window, baseline, mask, and calibration counter reset.

### Empty-room hold and disconnect

After calibration, three active results in a row with presence set clear the empty timer. When presence then goes false, the published flag stays true until `LEAVE_CONFIRM_SECS` (10.0 s) of absence. If no UDP packet arrives for `DISCONNECT_TIMEOUT` (5.0 s), the node publishes a disconnected payload and starts calibration over on the next packet.

`ROOM_ID` (default `room_a`), `UDP_LISTEN_PORT` (default 5500), `CALIBRATION_DELAY`, and `ANCHOR_MAC` are read from the environment when the script starts.

## Wi-Fi credentials

Committed defaults use the placeholders `YOUR_SSID` and `YOUR_PASSWORD`. Set the real network before flashing.

```bash
. $IDF_PATH/export.sh
cd esp32/csi_rx    # or esp32/csi_tx
idf.py set-target esp32s3
idf.py menuconfig
```

In menuconfig, open **CSI RX Configuration** or **CSI TX Configuration** and replace the SSID and password. On the receiver, set **UDP target IP (Raspberry Pi)** to the room Pi (`CONFIG_CSI_UDP_TARGET_IP`; the committed value is `0.0.0.0`, which means unset). Save and exit, then build. `scripts/flash_esp32.sh` writes the same keys from `--wifi-ssid`, `--wifi-pass`, and `--pi-host`.

Passive firmware has no SSID. Set the anchor BSSID and channel under **CSI Passive Configuration**, or pass `--anchor-mac` and `--channel` to the flash script.

## Validation

`scripts/validate_passive.py` listens for active CSI on UDP port 5500 and passive CSI on UDP port 5501, runs two copies of the detector, and writes a CSV. The script defines pass targets for that comparison. Results are not yet published.

## Mesh transport & logging

Room Pis reach the command node over Reticulum, which encrypts each packet to the destination identity. MQTT stays on `localhost:1883` as the handoff between `csi_processor.py` and `reticulum_bridge.py` (`axon/csi/raw`, `axon/detection`).

The bridge sends two packets to the command destination. The detection packet omits the heatmap, because the float array exceeds Reticulum's 500-byte MTU. The heatmap packet carries the same room with each bin quantized to an integer from 0 to 15. The command node announces that destination every 60 seconds. Until a room bridge has seen the announce, it drops detections. The command hub listens on TCP port 4242; the dashboard is `http://axon-command.local:5000`.

Each accepted detection is appended to `evidence_store/evidence_chain.jsonl`. The record hash is SHA-256 of `prev_hash + ":" + JSON(event)` with sorted keys. The first `prev_hash` is `genesis`, and a restart continues from the last line of the file. The dashboard calls `/api/evidence/verify` every 10 seconds. `scripts/deploy.sh` deletes the chain file on the command node before a deploy.

The dashboard keeps 60 spectrogram rows and paints deviation against `HEAT_MAX` (15.0).

## Quick start

### Flash the ESP32-S3

Requires [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/) for `esp32s3`.

```bash
./scripts/flash_esp32.sh tx --wifi-ssid YOUR_SSID --wifi-pass YOUR_PASSWORD
./scripts/flash_esp32.sh rx --wifi-ssid YOUR_SSID --wifi-pass YOUR_PASSWORD --pi-host axon-room-a.local
./scripts/flash_esp32.sh passive --anchor-mac aa:bb:cc:dd:ee:ff --channel 6
```

![Flashing ESP32 TX](https://github.com/jmendoza-10/axon-nervous-system-poc/releases/download/v0.1.0/flashing_esp32_tx_compressed.gif)

For a passive board, run `scripts/passive_serial_bridge.py --pi-host <room-pi>` on the laptop that has the USB serial port.

### Flash a Raspberry Pi SD card

```bash
./scripts/flash_pi_sd.sh \
  --board pi4 \
  --role command \
  --wifi-ssid YOUR_SSID \
  --wifi-pass YOUR_PASSWORD

./scripts/flash_pi_sd.sh \
  --board pi5 \
  --role room \
  --room-id room_a \
  --wifi-ssid YOUR_SSID \
  --wifi-pass YOUR_PASSWORD
```

![Flashing Raspberry Pi SD card](https://github.com/jmendoza-10/axon-nervous-system-poc/releases/download/v0.1.0/flashing_rpi_compressed.gif)

The script asks which disk to write and prompts for the Linux password when `--password` is omitted. The default user is `axon`.

| Flag | Default | Description |
|------|---------|-------------|
| `--board` | `pi4` | `pi4` or `pi5` |
| `--role` | `room` | `command` or `room` |
| `--room-id` | `room_a` | Room identifier for a room node |
| `--hostname` | auto | Hostname derived from role and room id |
| `--user` | `axon` | Linux username |
| `--password` | prompted | Linux password |
| `--wifi-ssid` | — | Wi-Fi network name |
| `--wifi-pass` | — | Wi-Fi passphrase |
| `--skip-download` | — | Reuse a cached OS image |

After first boot (about 60 s):

```bash
ssh axon@axon-command.local
ssh axon@axon-room-a.local
sudo bash /boot/firmware/axon-firstboot/setup.sh
```

Manual setup, if you skip the flasher:

```bash
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_pi_common.sh | bash
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_command_node.sh | bash
curl -sSL https://raw.githubusercontent.com/jmendoza-10/axon-nervous-system-poc/main/scripts/setup_room_node.sh | bash -s room_a
```

Open `http://axon-command.local:5000`. Leave the room during the 20 s calibration delay, then walk back in. The card shows presence, motion, variance, and the scrolling subcarrier heatmap.

### Deploy updates

```bash
bash scripts/deploy.sh all
bash scripts/deploy.sh command
bash scripts/deploy.sh room-a
bash scripts/deploy.sh room-b
```

| Node | Service | Role |
|------|---------|------|
| Command | `axon-dashboard` | Flask, Socket.IO, Reticulum receiver, evidence log |
| Command | `axon-rnsd` | Reticulum daemon, TCP hub on port 4242 |
| Room | `axon-csi-processor` | UDP to MQTT detection |
| Room | `axon-reticulum-bridge` | MQTT to Reticulum |

```bash
journalctl -u axon-csi-processor -f
journalctl -u axon-dashboard -f
```

## Project structure

```
├── esp32/
│   ├── csi_tx/          # Active transmitter (ESP-IDF, ~100 Hz UDP broadcast)
│   ├── csi_rx/          # Active receiver (L-LTF CSI → UDP :5500)
│   └── csi_passive/     # Promiscuous sniffer (L-LTF CSI → UART)
├── pi/
│   ├── room_node/
│   │   ├── csi_processor.py
│   │   └── reticulum_bridge.py
│   └── command_node/
│       ├── dashboard.py
│       └── templates/index.html
└── scripts/
    ├── flash_esp32.sh
    ├── flash_pi_sd.sh
    ├── passive_serial_bridge.py
    ├── validate_passive.py
    ├── deploy.sh
    └── setup_*.sh
```

Phase 3 in the original plan — CSI from an OpenWrt access point, with no extra ESP32 — is not in this tree.
