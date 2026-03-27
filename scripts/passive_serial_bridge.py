#!/usr/bin/env python3
"""
Passive CSI Serial Bridge

Reads JSON CSI packets from the passive ESP32 sniffer via USB serial (UART stdout)
and forwards each packet as a UDP datagram to the room Pi's csi_processor.py.

This bridge is needed because the passive firmware uses WIFI_MODE_NULL (promiscuous
mode without AP association), so it cannot send UDP packets directly over WiFi.
The bridge runs on a laptop connected to the ESP32 via USB and the same LAN as the Pi.

Usage:
    python3 passive_serial_bridge.py [options]

    python3 passive_serial_bridge.py \\
        --serial /dev/cu.usbmodem101 \\
        --pi-host axon-room-a.local \\
        --pi-port 5500

    # Auto-detect serial port, target room_b Pi:
    python3 passive_serial_bridge.py --pi-host axon-room-b.local

Requirements:
    pip install pyserial
"""

import argparse
import json
import logging
import signal
import socket
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("Error: pyserial is required. Run: pip install pyserial", file=sys.stderr)
    sys.exit(1)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [bridge] %(levelname)s: %(message)s",
)
log = logging.getLogger("bridge")

DEFAULT_BAUD = 115200
DEFAULT_PORT = 5500


def detect_serial_port() -> str | None:
    """Return the first port that looks like an ESP32 USB device."""
    candidates = list(serial.tools.list_ports.comports())
    for p in candidates:
        desc = (p.description or "").lower()
        vid = p.vid or 0
        # Common ESP32-S3 VIDs: Espressif (0x303A), CP2102 (0x10C4), CH340 (0x1A86)
        if vid in (0x303A, 0x10C4, 0x1A86) or "esp" in desc or "uart" in desc or "serial" in desc:
            return p.device
    # Fallback: first available port
    return candidates[0].device if candidates else None


def resolve_host(hostname: str) -> str:
    try:
        ip = socket.gethostbyname(hostname)
        log.info("Resolved %s → %s", hostname, ip)
        return ip
    except socket.gaierror as e:
        log.error("Cannot resolve '%s': %s", hostname, e)
        sys.exit(1)


def run_bridge(serial_port: str, baud: int, pi_ip: str, pi_port: int, verbose: bool) -> None:
    log.info("Opening serial port %s @ %d baud", serial_port, baud)
    log.info("Forwarding CSI UDP → %s:%d", pi_ip, pi_port)

    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    stats = {"sent": 0, "dropped": 0, "bytes": 0, "start": time.time()}

    def _log_stats(signum=None, frame=None) -> None:
        elapsed = time.time() - stats["start"]
        rate = stats["sent"] / elapsed if elapsed > 0 else 0.0
        log.info(
            "Stats: sent=%d  dropped=%d  %.2f pkt/s  %.1f KB/s",
            stats["sent"], stats["dropped"], rate,
            stats["bytes"] / 1024 / elapsed if elapsed > 0 else 0,
        )

    signal.signal(signal.SIGUSR1, _log_stats)

    try:
        ser = serial.Serial(serial_port, baud, timeout=1.0)
    except serial.SerialException as e:
        log.error("Cannot open serial port: %s", e)
        sys.exit(1)

    log.info("Bridge running. Send SIGUSR1 for stats. Ctrl+C to stop.")

    try:
        while True:
            try:
                line = ser.readline()
            except serial.SerialException as e:
                log.error("Serial read error: %s — reconnecting in 2s", e)
                time.sleep(2)
                try:
                    ser.close()
                    ser = serial.Serial(serial_port, baud, timeout=1.0)
                    log.info("Reconnected to %s", serial_port)
                except serial.SerialException:
                    pass
                continue

            if not line:
                continue

            line = line.strip()
            if not line:
                continue

            # Skip ESP-IDF log lines (start with 'I (', 'W (', 'E (', etc.)
            if line and line[0:1] in (b"I", b"W", b"E", b"D") and b"(" in line[:6]:
                if verbose:
                    log.debug("ESP log: %s", line.decode("utf-8", errors="replace"))
                continue

            try:
                pkt = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                stats["dropped"] += 1
                if verbose:
                    log.debug("Non-JSON line: %s", line[:80])
                continue

            # Validate expected fields
            if "data" not in pkt or "mac" not in pkt:
                stats["dropped"] += 1
                continue

            payload = line  # forward the raw bytes as-is
            try:
                udp_sock.sendto(payload, (pi_ip, pi_port))
                stats["sent"] += 1
                stats["bytes"] += len(payload)

                if verbose and stats["sent"] % 10 == 0:
                    log.debug(
                        "Forwarded pkt #%d  mac=%s  subcarriers=%d",
                        stats["sent"], pkt.get("mac"), len(pkt.get("data", [])),
                    )
            except OSError as e:
                stats["dropped"] += 1
                log.warning("UDP send error: %s", e)

    except KeyboardInterrupt:
        log.info("Interrupted by user.")
        _log_stats()
    finally:
        ser.close()
        udp_sock.close()
        log.info("Bridge stopped.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Serial-to-UDP bridge for the Axon passive CSI sniffer"
    )
    parser.add_argument(
        "--serial", metavar="PORT",
        help="Serial port (auto-detected if omitted)",
    )
    parser.add_argument(
        "--baud", type=int, default=DEFAULT_BAUD,
        help=f"Serial baud rate (default: {DEFAULT_BAUD})",
    )
    parser.add_argument(
        "--pi-host", metavar="HOST", default="axon-room-a.local",
        help="Pi hostname or IP (default: axon-room-a.local)",
    )
    parser.add_argument(
        "--pi-port", type=int, default=DEFAULT_PORT,
        help=f"UDP port on the Pi (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Enable debug logging (per-packet)",
    )
    args = parser.parse_args()

    serial_port = args.serial or detect_serial_port()
    if not serial_port:
        log.error("No serial port found. Connect the ESP32 via USB or use --serial PORT.")
        sys.exit(1)

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    pi_ip = resolve_host(args.pi_host)
    run_bridge(serial_port, args.baud, pi_ip, args.pi_port, args.verbose)


if __name__ == "__main__":
    main()
