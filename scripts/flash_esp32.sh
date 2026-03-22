#!/usr/bin/env bash
# Flash ESP32-S3 boards with CSI firmware
# Requires ESP-IDF to be installed: https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Usage: $0 <tx|rx> [port]"
    echo ""
    echo "  tx   - Flash CSI transmitter firmware"
    echo "  rx   - Flash CSI receiver firmware"
    echo "  port - Serial port (default: /dev/ttyUSB0 or /dev/ttyACM0)"
    echo ""
    echo "Prerequisites:"
    echo "  - ESP-IDF installed and sourced (. \$IDF_PATH/export.sh)"
    echo "  - ESP32-S3 connected via USB"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

FIRMWARE="$1"
PORT="${2:-}"

# Auto-detect port if not specified
if [ -z "$PORT" ]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: ESP32-S3 shows up as cu.usbmodem* (built-in USB) or
        # cu.SLAB_USBtoUART / cu.usbserial-* (CP210x/CH340 USB-UART chips)
        PORT=$(ls /dev/cu.usbmodem* /dev/cu.SLAB_USBtoUART* /dev/cu.usbserial-* 2>/dev/null | head -1)
    else
        # Linux
        PORT=$(ls /dev/ttyACM0 /dev/ttyUSB0 2>/dev/null | head -1)
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
        echo "  $0 $FIRMWARE /dev/cu.usbmodem1234"
        exit 1
    fi

    echo "Auto-detected port: $PORT"
fi

# Check ESP-IDF
if [ -z "${IDF_PATH:-}" ]; then
    echo "Error: ESP-IDF not found. Run: . \$IDF_PATH/export.sh"
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

# Set target to ESP32-S3
idf.py set-target esp32s3

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
