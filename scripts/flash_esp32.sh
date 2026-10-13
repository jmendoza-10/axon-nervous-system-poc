#!/usr/bin/env bash
# Flash ESP32-S3 boards with CSI firmware
# Requires ESP-IDF to be installed: https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <tx|rx|passive> [options]"
    echo ""
    echo "  tx      - Flash CSI transmitter firmware (requires WiFi creds)"
    echo "  rx      - Flash CSI receiver firmware (requires WiFi creds)"
    echo "  passive - Flash passive CSI sniffer firmware (no WiFi creds needed)"
    echo ""
    echo "Required for tx/rx:"
    echo "  --wifi-ssid <ssid>  WiFi network name (ESP32 must join the same network as the Pi)"
    echo "  --wifi-pass <pass>  WiFi password"
    echo ""
    echo "Optional:"
    echo "  --port <port>             Serial port (auto-detected if not specified)"
    echo "  --pi-host <host>          Target Pi hostname/IP for CSI UDP stream (rx only, default: axon-room-a.local)"
    echo "  --anchor-mac <mac>        Anchor AP BSSID to filter CSI (passive only, e.g. aa:bb:cc:dd:ee:ff)"
    echo "  --channel <ch>            WiFi channel to monitor (passive only, default: 6)"
    echo ""
    echo "Prerequisites:"
    echo "  1. ESP-IDF installed and sourced:  . ~/workspace/opensource/esp/esp-idf/export.sh"
    echo "  2. ESP32-S3 connected via USB"
    echo ""
    echo "Active mode (tx/rx) — each room needs two ESP32-S3 boards:"
    echo "  - TX: broadcasts packets that create CSI signatures"
    echo "  - RX: captures CSI from TX and streams it to the room Pi via UDP :5500"
    echo ""
    echo "Passive mode — single ESP32-S3, no WiFi association required:"
    echo "  - Sniffs ambient frames from anchor AP in promiscuous mode"
    echo "  - Outputs CSI JSON over UART (USB serial)"
    echo "  - Run scripts/passive_serial_bridge.py on your laptop to forward to Pi"
    echo ""
    echo "Examples:"
    echo "  # Room A active pair (Pi at axon-room-a.local)"
    echo "  $0 tx --wifi-ssid YOUR_SSID --wifi-pass YOUR_PASSWORD"
    echo "  $0 rx --wifi-ssid YOUR_SSID --wifi-pass YOUR_PASSWORD --pi-host axon-room-a.local"
    echo ""
    echo "  # Passive sniffer (Phase 2)"
    echo "  $0 passive --anchor-mac aa:bb:cc:dd:ee:ff --channel 6"
    echo "  # Then on laptop: python3 scripts/passive_serial_bridge.py --pi-host axon-room-a.local"
    echo ""
    echo "  # Specify serial port manually"
    echo "  $0 tx --wifi-ssid YOUR_SSID --wifi-pass YOUR_PASSWORD --port /dev/cu.usbmodem1234"
    exit 0
}

if [ $# -lt 1 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    usage
fi

FIRMWARE="$1"
shift

PORT=""
WIFI_SSID=""
WIFI_PASS=""
PI_HOST="axon-room-a.local"
ANCHOR_MAC=""
CHANNEL="6"

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)        PORT="$2";       shift 2 ;;
        --wifi-ssid)   WIFI_SSID="$2";  shift 2 ;;
        --wifi-pass)   WIFI_PASS="$2";  shift 2 ;;
        --pi-host)     PI_HOST="$2";    shift 2 ;;
        --anchor-mac)  ANCHOR_MAC="$2"; shift 2 ;;
        --channel)     CHANNEL="$2";    shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# Passive mode doesn't need WiFi credentials
if [[ "$FIRMWARE" != "passive" ]]; then
    if [ -z "$WIFI_SSID" ] || [ -z "$WIFI_PASS" ]; then
        echo "Error: --wifi-ssid and --wifi-pass are required for $FIRMWARE firmware."
        echo "  The ESP32 must connect to the same WiFi network as the Raspberry Pi."
        echo ""
        echo "  $0 $FIRMWARE --wifi-ssid <SSID> --wifi-pass <PASSWORD>"
        exit 1
    fi
fi

# Auto-detect port if not specified
if [ -z "$PORT" ]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        PORT=$(ls /dev/cu.usbmodem* /dev/cu.SLAB_USBtoUART* /dev/cu.usbserial-* 2>/dev/null | head -1 || true)
    else
        PORT=$(ls /dev/ttyACM0 /dev/ttyUSB0 2>/dev/null | head -1 || true)
    fi

    if [ -z "$PORT" ]; then
        echo "Error: No ESP32 serial port found."
        echo ""
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "Available ports:"
            ls /dev/cu.* 2>/dev/null | grep -v Bluetooth || echo "  (none)"
        else
            echo "Available ports:"
            ls /dev/tty{ACM,USB}* 2>/dev/null || echo "  (none)"
        fi
        echo ""
        echo "Connect the ESP32 via USB and retry, or specify the port:"
        echo "  $0 $FIRMWARE --port /dev/cu.usbmodem1234"
        exit 1
    fi

    echo "Auto-detected port: $PORT"
fi

# Check ESP-IDF
if [ -z "${IDF_PATH:-}" ]; then
    echo "Error: ESP-IDF not found. Run: . ~/workspace/opensource/esp/esp-idf/export.sh"
    exit 1
fi

case "$FIRMWARE" in
    tx)
        echo "=== Flashing CSI Transmitter to $PORT ==="
        cd "$PROJECT_DIR/esp32/csi_tx"
        ;;
    rx)
        echo "=== Flashing CSI Receiver to $PORT ==="
        cd "$PROJECT_DIR/esp32/csi_rx"
        ;;
    passive)
        echo "=== Flashing Passive CSI Sniffer to $PORT ==="
        cd "$PROJECT_DIR/esp32/csi_passive"
        ;;
    *)
        usage
        ;;
esac

# Write sdkconfig.defaults with build-time config
DEFAULTS_FILE="sdkconfig.defaults"

if [[ "$FIRMWARE" == "passive" ]]; then
    # Passive mode: write anchor MAC and channel; no WiFi credentials needed
    EXISTING=$(grep -v "^CONFIG_CSI_ANCHOR_MAC\|^CONFIG_CSI_CHANNEL" "$DEFAULTS_FILE" 2>/dev/null || true)
    {
        echo "$EXISTING"
        if [ -n "$ANCHOR_MAC" ]; then
            echo "CONFIG_CSI_ANCHOR_MAC=\"${ANCHOR_MAC}\""
        fi
        echo "CONFIG_CSI_CHANNEL=${CHANNEL}"
    } > "$DEFAULTS_FILE.tmp" && mv "$DEFAULTS_FILE.tmp" "$DEFAULTS_FILE"
    echo "Passive sniffer config: anchor_mac=${ANCHOR_MAC:-<all>}  channel=${CHANNEL}"
    echo ""
    echo "IMPORTANT: After flashing, run the serial bridge on your laptop:"
    echo "  python3 $SCRIPT_DIR/passive_serial_bridge.py --pi-host <room-pi-host>"

elif [ -n "$WIFI_SSID" ]; then
    # Active mode: resolve Pi hostname and write WiFi credentials
    PI_IP=""
    if [[ "$FIRMWARE" == "rx" ]]; then
        echo "Resolving $PI_HOST..."
        PI_IP=$(python3 -c "import socket; print(socket.gethostbyname('$PI_HOST'))" 2>/dev/null || true)
        if [ -z "$PI_IP" ]; then
            echo "Error: Could not resolve '$PI_HOST'. Make sure the Pi is online."
            exit 1
        fi
        echo "  Resolved $PI_HOST → $PI_IP"
    fi

    # Preserve existing defaults, stripping credential lines we'll rewrite
    EXISTING=$(grep -v "^CONFIG_CSI_TX_SSID\|^CONFIG_CSI_TX_PASSWORD\|^CONFIG_CSI_RX_SSID\|^CONFIG_CSI_RX_PASSWORD\|^CONFIG_CSI_UDP_TARGET_IP" "$DEFAULTS_FILE" 2>/dev/null || true)
    {
        echo "$EXISTING"
        if [[ "$FIRMWARE" == "tx" ]]; then
            echo "CONFIG_CSI_TX_SSID=\"${WIFI_SSID}\""
            echo "CONFIG_CSI_TX_PASSWORD=\"${WIFI_PASS}\""
        else
            echo "CONFIG_CSI_RX_SSID=\"${WIFI_SSID}\""
            echo "CONFIG_CSI_RX_PASSWORD=\"${WIFI_PASS}\""
            echo "CONFIG_CSI_UDP_TARGET_IP=\"${PI_IP}\""
        fi
    } > "$DEFAULTS_FILE.tmp" && mv "$DEFAULTS_FILE.tmp" "$DEFAULTS_FILE"
fi

# Set target to ESP32-S3 and clean (ensures sdkconfig.defaults are applied)
idf.py set-target esp32s3
idf.py fullclean

# Build
echo "Building firmware..."
idf.py build

# Flash
echo "Flashing to $PORT..."
idf.py -p "$PORT" flash

# Monitor (optional - Ctrl+] to exit)
echo ""
echo "=== Flash complete! ==="
echo "To monitor serial output: idf.py -p $PORT monitor"
read -p "Start serial monitor now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    idf.py -p "$PORT" monitor
fi
