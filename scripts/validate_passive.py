#!/usr/bin/env python3
"""
Passive CSI Sniffer - End-to-End Validation Tool (Phase 2c)

Compares passive vs active CSI detection side-by-side in a live environment.
Both paths feed into separate CSIDetector instances; results are logged to a
CSV file and printed to stdout for real-time monitoring.

The tool reads from two UDP ports simultaneously:
  - Active input:  port 5500 (standard room-node port, fed by csi_rx firmware)
  - Passive input: port 5501 (fed by passive_serial_bridge.py)

Run both the passive serial bridge and the active rx on the same Pi, or redirect
them to different ports by passing --active-port / --passive-port.

Usage:
    # Both active and passive feeding the same Pi
    python3 validate_passive.py --output results.csv

    # Point each at a different host (if active is on Pi A, passive on Pi B)
    python3 validate_passive.py \\
        --active-host axon-room-a.local --active-port 5500 \\
        --passive-host 127.0.0.1 --passive-port 5501 \\
        --output results.csv --duration 300

Requirements:
    pip install numpy
"""

import argparse
import csv
import json
import logging
import os
import socket
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone

import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
log = logging.getLogger("validate")

# ── Detection parameters (mirror csi_processor.py Phase 2b tuning) ────────────
WINDOW_DURATION_SECS = 30.0
MOTION_WINDOW_SECS = 0.5
BREATHING_WINDOW_SECS = 13.0
MOTION_THRESHOLD = 2.5
PRESENCE_THRESHOLD = 6.0
BREATHING_THRESHOLD = 1.5
MOTION_RATE_GATE_HZ = 30.0
CALIBRATION_SAMPLES = 100   # shorter for validation runs
CALIBRATION_DELAY = 10      # seconds (shortened for validation)
_DEQUE_MAXLEN = 4000


class CSIDetector:
    """Inline port of csi_processor.CSIDetector for side-by-side comparison."""

    def __init__(self, label: str):
        self.label = label
        self.window: deque = deque(maxlen=_DEQUE_MAXLEN)
        self.baseline: np.ndarray | None = None
        self.calibrating = True
        self._calibration_count = 0
        self._null_mask: np.ndarray | None = None
        self._last_sample_time: float | None = None
        self._rate_intervals: deque = deque(maxlen=20)
        self._ready = False

    def _estimate_sample_rate(self) -> float:
        if len(self._rate_intervals) < 2:
            return 0.0
        avg = float(np.mean(list(self._rate_intervals)))
        return 1.0 / avg if avg > 0 else 0.0

    def _evict_old(self, now: float) -> None:
        cutoff = now - WINDOW_DURATION_SECS
        while self.window and self.window[0][0] < cutoff:
            self.window.popleft()

    def _samples_in_window(self, now: float, secs: float) -> list:
        cutoff = now - secs
        return [a for ts, a in self.window if ts >= cutoff]

    def update(self, amplitudes: list) -> dict:
        now = time.time()
        raw = np.array(amplitudes, dtype=np.float32)

        if self._null_mask is None:
            self._null_mask = raw != 0.0
        arr = raw[self._null_mask]

        if self._last_sample_time is not None:
            interval = now - self._last_sample_time
            if 0.0 < interval < 2.0:
                self._rate_intervals.append(interval)
        self._last_sample_time = now

        self._evict_old(now)
        self.window.append((now, arr))

        if self.calibrating:
            self._calibration_count += 1
            if self._calibration_count < CALIBRATION_SAMPLES:
                return {"status": "calibrating", "progress": self._calibration_count / CALIBRATION_SAMPLES}

        if self.calibrating:
            stacked = np.stack([a for _, a in self.window])
            self.baseline = np.mean(stacked, axis=0)
            self.calibrating = False
            self._ready = True
            log.info("[%s] Calibration complete (%d subcarriers)", self.label, len(self.baseline))
            return {"status": "calibrated"}

        if arr.shape != self.baseline.shape:
            log.warning("[%s] Subcarrier count changed — resetting calibration", self.label)
            self.window.clear()
            self.baseline = None
            self.calibrating = True
            self._calibration_count = 0
            self._null_mask = None
            self._ready = False
            return {"status": "calibrating", "progress": 0.0}

        deviation = arr - self.baseline
        variance = float(np.var(deviation))
        std_dev = float(np.std(deviation))
        sample_rate_hz = self._estimate_sample_rate()

        motion_samples = self._samples_in_window(now, MOTION_WINDOW_SECS)
        temporal_var = float(np.mean(np.var(np.stack(motion_samples), axis=0))) if len(motion_samples) >= 2 else 0.0

        motion_gated = 0.0 < sample_rate_hz < MOTION_RATE_GATE_HZ

        breathing_samples = self._samples_in_window(now, BREATHING_WINDOW_SECS)
        breathing_var = float(np.mean(np.var(np.stack(breathing_samples), axis=0))) if len(breathing_samples) >= 10 else 0.0

        presence = variance > PRESENCE_THRESHOLD
        motion = (not motion_gated) and (temporal_var > MOTION_THRESHOLD)

        return {
            "status": "active",
            "label": self.label,
            "presence": presence,
            "motion": motion,
            "variance": round(variance, 3),
            "std_dev": round(std_dev, 3),
            "temporal_var": round(temporal_var, 3),
            "breathing_var": round(breathing_var, 4),
            "sample_rate_hz": round(sample_rate_hz, 1),
            "motion_gated": motion_gated,
            "timestamp": now,
        }


class ChannelReader:
    """Reads CSI packets from a UDP port and feeds them to a CSIDetector."""

    def __init__(self, label: str, host: str, port: int, anchor_mac: str = ""):
        self.label = label
        self.host = host
        self.port = port
        self.anchor_mac = anchor_mac.lower()
        self.detector = CSIDetector(label)
        self.latest: dict | None = None
        self.pkt_count = 0
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._running = False

    def start(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._listen, daemon=True, name=f"reader-{self.label}")
        self._thread.start()

    def stop(self) -> None:
        self._running = False

    def get_latest(self) -> dict | None:
        with self._lock:
            return self.latest

    def _listen(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.host, self.port))
        sock.settimeout(1.0)
        log.info("[%s] Listening on %s:%d", self.label, self.host or "0.0.0.0", self.port)

        while self._running:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break

            try:
                pkt = json.loads(data)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue

            if self.anchor_mac:
                src = pkt.get("mac", "").lower()
                if src != self.anchor_mac:
                    continue

            amplitudes = pkt.get("data", [])
            if not amplitudes:
                continue

            result = self.detector.update(amplitudes)
            self.pkt_count += 1

            with self._lock:
                self.latest = result

        sock.close()


def run_validation(
    active_bind: str, active_port: int,
    passive_bind: str, passive_port: int,
    anchor_mac: str,
    output_path: str,
    duration_secs: float,
) -> None:
    active = ChannelReader("active", active_bind, active_port)
    passive = ChannelReader("passive", passive_bind, passive_port, anchor_mac=anchor_mac)

    log.info("Starting validation. Duration: %ss. Output: %s", duration_secs or "∞", output_path)
    log.info("Calibration delay: %ds — PLEASE LEAVE THE ROOM NOW.", CALIBRATION_DELAY)
    time.sleep(CALIBRATION_DELAY)

    active.start()
    passive.start()

    log.info("Listening for CSI data on both channels...")
    log.info("  Active  → port %d", active_port)
    log.info("  Passive → port %d", passive_port)
    log.info("")
    log.info("%-8s  %-8s %-8s  %-6s  %-8s %-8s  %-6s  %-6s  %-6s",
             "Time", "Act.Prs", "Pas.Prs", "Match?", "Act.Var", "Pas.Var", "A.Rate", "P.Rate", "P.Gated")

    fieldnames = [
        "timestamp", "elapsed_s",
        "active_presence", "passive_presence", "match",
        "active_motion", "passive_motion",
        "active_variance", "passive_variance",
        "active_temporal_var", "passive_temporal_var",
        "active_breathing_var", "passive_breathing_var",
        "active_sample_rate_hz", "passive_sample_rate_hz",
        "passive_motion_gated",
        "active_packets", "passive_packets",
    ]

    start = time.time()

    with open(output_path, "w", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        csvfile.flush()

        try:
            while True:
                now = time.time()
                elapsed = now - start

                if duration_secs and elapsed >= duration_secs:
                    log.info("Duration reached (%.0fs). Stopping.", duration_secs)
                    break

                time.sleep(1.0)

                a = active.get_latest()
                p = passive.get_latest()

                if not a or not p:
                    log.info("  Waiting for both channels to calibrate...")
                    continue

                if a.get("status") != "active" or p.get("status") != "active":
                    a_status = a.get("status", "?")
                    p_status = p.get("status", "?")
                    prog_a = f" ({a.get('progress', 0):.0%})" if a_status == "calibrating" else ""
                    prog_p = f" ({p.get('progress', 0):.0%})" if p_status == "calibrating" else ""
                    log.info("  Calibrating — active: %s%s  passive: %s%s",
                             a_status, prog_a, p_status, prog_p)
                    continue

                match = a["presence"] == p["presence"]
                elapsed_str = f"{int(elapsed // 60):02d}:{int(elapsed % 60):02d}"

                log.info(
                    "%-8s  %-8s %-8s  %-6s  %-8.2f %-8.2f  %-6.1f  %-6.1f  %-6s",
                    elapsed_str,
                    "YES" if a["presence"] else "NO",
                    "YES" if p["presence"] else "NO",
                    "OK" if match else "DIFF",
                    a["variance"], p["variance"],
                    a["sample_rate_hz"], p["sample_rate_hz"],
                    "yes" if p["motion_gated"] else "no",
                )

                row = {
                    "timestamp": datetime.fromtimestamp(now, tz=timezone.utc).isoformat(),
                    "elapsed_s": round(elapsed, 1),
                    "active_presence": a["presence"],
                    "passive_presence": p["presence"],
                    "match": match,
                    "active_motion": a["motion"],
                    "passive_motion": p["motion"],
                    "active_variance": a["variance"],
                    "passive_variance": p["variance"],
                    "active_temporal_var": a["temporal_var"],
                    "passive_temporal_var": p["temporal_var"],
                    "active_breathing_var": a["breathing_var"],
                    "passive_breathing_var": p["breathing_var"],
                    "active_sample_rate_hz": a["sample_rate_hz"],
                    "passive_sample_rate_hz": p["sample_rate_hz"],
                    "passive_motion_gated": p["motion_gated"],
                    "active_packets": active.pkt_count,
                    "passive_packets": passive.pkt_count,
                }
                writer.writerow(row)
                csvfile.flush()

        except KeyboardInterrupt:
            log.info("Interrupted by user.")

    active.stop()
    passive.stop()

    # Summary
    _print_summary(output_path)


def _print_summary(csv_path: str) -> None:
    """Print an accuracy summary from the CSV results file."""
    rows = []
    try:
        with open(csv_path, newline="") as f:
            reader = csv.DictReader(f)
            rows = [r for r in reader if r.get("active_presence")]
    except (OSError, KeyError):
        return

    if not rows:
        log.info("No comparison rows recorded.")
        return

    total = len(rows)
    matches = sum(1 for r in rows if r["match"] == "True")
    accuracy = matches / total * 100 if total else 0.0

    avg_active_rate = sum(float(r["active_sample_rate_hz"]) for r in rows) / total
    avg_passive_rate = sum(float(r["passive_sample_rate_hz"]) for r in rows) / total
    gated_rows = sum(1 for r in rows if r["passive_motion_gated"] == "True")

    log.info("")
    log.info("═══ VALIDATION SUMMARY ═══════════════════════════════")
    log.info("  Total comparison samples : %d", total)
    log.info("  Presence agreement       : %d / %d  (%.1f%%)", matches, total, accuracy)
    log.info("  Active avg sample rate   : %.1f Hz", avg_active_rate)
    log.info("  Passive avg sample rate  : %.1f Hz", avg_passive_rate)
    log.info("  Passive motion gated     : %d / %d rows", gated_rows, total)
    log.info("")

    if accuracy >= 90.0:
        log.info("  GO: Passive mode meets 90%% presence accuracy target.")
    elif accuracy >= 75.0:
        log.info("  CONDITIONAL GO: Presence accuracy %.1f%% — tune thresholds before prod.", accuracy)
    else:
        log.info("  NO-GO: Presence accuracy %.1f%% is below 75%% minimum.", accuracy)

    log.info("  Full results: %s", csv_path)
    log.info("══════════════════════════════════════════════════════")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Axon Phase 2c — passive vs active CSI validation"
    )
    parser.add_argument("--active-host", default="0.0.0.0",
                        help="Bind address for active UDP input (default: 0.0.0.0)")
    parser.add_argument("--active-port", type=int, default=5500,
                        help="UDP port for active CSI packets (default: 5500)")
    parser.add_argument("--passive-host", default="0.0.0.0",
                        help="Bind address for passive UDP input (default: 0.0.0.0)")
    parser.add_argument("--passive-port", type=int, default=5501,
                        help="UDP port for passive CSI packets from serial bridge (default: 5501)")
    parser.add_argument("--anchor-mac", default="",
                        help="Anchor AP BSSID to filter passive frames (optional)")
    parser.add_argument("--output", default=f"validation_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
                        help="CSV output file path")
    parser.add_argument("--duration", type=float, default=0,
                        help="Stop after N seconds (default: run until Ctrl+C)")
    args = parser.parse_args()

    log.info("Axon Phase 2c Validation Tool")
    log.info("  Active  UDP: %s:%d", args.active_host or "0.0.0.0", args.active_port)
    log.info("  Passive UDP: %s:%d", args.passive_host or "0.0.0.0", args.passive_port)
    log.info("  Anchor MAC : %s", args.anchor_mac or "<all>")
    log.info("  Output     : %s", args.output)

    run_validation(
        active_bind=args.active_host,
        active_port=args.active_port,
        passive_bind=args.passive_host,
        passive_port=args.passive_port,
        anchor_mac=args.anchor_mac,
        output_path=args.output,
        duration_secs=args.duration,
    )


if __name__ == "__main__":
    main()
