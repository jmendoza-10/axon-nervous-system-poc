#!/usr/bin/env bash
# Flash ESP32-S3 boards with CSI firmware
# Requires ESP-IDF to be installed: https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <tx|rx> --wifi-ssid <SSID> --wifi-pass <PASSWORD> [options]"
    echo ""
    echo "  tx   - Flash CSI transmitter firmware"
    echo "  rx   - Flash CSI receiver firmware"
    echo ""
    echo "Required:"
    echo "  --wifi-ssid <ssid>  WiFi network name (ESP32 must join the same network as the Pi)"
    echo "  --wifi-pass <pass>  WiFi password"
    echo ""
    echo "Optional:"
    echo "  --port <port>       Serial port (auto-detected if not specified)"
    echo "  --pi-host <host>    Target Pi hostname/IP for CSI UDP stream (rx only, default: axon-room-a.local)"
    echo ""
    echo "Prerequisites:"
    echo "  1. ESP-IDF installed and sourced:  . ~/workspace/opensource/esp/esp-idf/export.sh"
    echo "  2. ESP32-S3 connected via USB"
    echo ""
    echo "Each room needs two ESP32-S3 boards flashed to the same WiFi network:"
    echo "  - TX: broadcasts packets that create CSI signatures"
    echo "  - RX: captures CSI from TX and streams it to the room Pi via UDP :5500"
    echo ""
    echo "Examples:"
    echo "  # Room A pair (Pi at axon-room-a.local)"
    echo "  $0 tx --wifi-ssid MyWiFi --wifi-pass secret"
    echo "  $0 rx --wifi-ssid MyWiFi --wifi-pass secret --pi-host axon-room-a.local"
    echo ""
    echo "  # Room B pair (Pi at axon-room-b.local)"
    echo "  $0 tx --wifi-ssid MyWiFi --wifi-pass secret"
    echo "  $0 rx --wifi-ssid MyWiFi --wifi-pass secret --pi-host axon-room-b.local"
    echo ""
    echo "  # Specify serial port manually"
    echo "  $0 tx --wifi-ssid MyWiFi --wifi-pass secret --port /dev/cu.usbmodem1234"
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

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      PORT="$2";      shift 2 ;;
        --wifi-ssid) WIFI_SSID="$2"; shift 2 ;;
        --wifi-pass) WIFI_PASS="$2"; shift 2 ;;
        --pi-host)   PI_HOST="$2";   shift 2 ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# Require WiFi credentials — without these the ESP32 can't join the network
# and will silently fail to produce any CSI data
if [ -z "$WIFI_SSID" ] || [ -z "$WIFI_PASS" ]; then
    echo "Error: --wifi-ssid and --wifi-pass are required."
    echo "  The ESP32 must connect to the same WiFi network as the Raspberry Pi."
    echo ""
    echo "  $0 $FIRMWARE --wifi-ssid <SSID> --wifi-pass <PASSWORD>"
    exit 1
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
    *)
        usage
        ;;
esac

# Write sdkconfig.defaults with WiFi credentials if provided
DEFAULTS_FILE="sdkconfig.defaults"

if [ -n "$WIFI_SSID" ]; then
    # Resolve Pi hostname to IP (firmware uses inet_addr which needs an IP)
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
