#!/usr/bin/env python3
"""
CSI Processor - Room Node (Pi #2 / Pi #3)

Receives raw CSI JSON data from ESP32 via UDP (active or passive/anchor mode),
runs presence/motion detection, and publishes results to MQTT.

Phase 2b: supports passive CSI from anchor AP beacons (~10 Hz) via:
  - Time-based sample windows (vs. sample-count)
  - Anchor MAC filter to discard non-anchor frames
  - Sample rate estimation with motion-detection gating below 30 Hz
  - Re-tuned thresholds for lower-rate passive signal
"""

import json
import os
import socket
import time
import threading
import logging
from collections import deque

import numpy as np
import paho.mqtt.client as mqtt

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
log = logging.getLogger("csi_processor")

# --- Configuration ---
UDP_LISTEN_PORT = 5500
MQTT_BROKER = "localhost"
MQTT_PORT = 1883
MQTT_TOPIC_RAW = "axon/csi/raw"
MQTT_TOPIC_DETECTION = "axon/detection"
ROOM_ID = "room_a"

# Passive/anchor MAC filter — set to AP BSSID (e.g. "aa:bb:cc:dd:ee:ff") to
# discard non-anchor frames.  Leave empty to accept all sources (active mode).
ANCHOR_MAC = ""

# Detection time-based windows (replace sample-count constants; work at any rate)
WINDOW_DURATION_SECS = 30.0    # Total rolling window duration (was WINDOW_SIZE=500 @ 100 Hz → 5 s)
MOTION_WINDOW_SECS = 0.5       # Window for fast motion detection (was 5 samples @ 100 Hz → 50 ms)
BREATHING_WINDOW_SECS = 13.0   # Window for breathing / still-presence (was 400 samples @ 100 Hz → 4 s)

# Re-tuned thresholds for passive lower-rate signal (~10 Hz anchor beacons).
# These are starting points — real-environment calibration is required (see EMB-14 Phase 2c).
MOTION_THRESHOLD = 2.5         # Temporal variance for motion (was 3.0 at 100 Hz)
PRESENCE_THRESHOLD = 6.0       # Baseline-deviation variance for presence (was 8.0)
BREATHING_THRESHOLD = 1.5      # Breathing temporal variance threshold (unchanged)

# Motion detection is unreliable below ~30 Hz; gate it when rate is too low.
MOTION_RATE_GATE_HZ = 30.0

CALIBRATION_SAMPLES = 200      # Samples to collect for baseline (takes ~20 s at 10 Hz)
CALIBRATION_DELAY = 20         # Seconds to wait before starting calibration

# Deque capacity — large enough to never hit in practice at any expected rate.
# At 10 Hz, 30 s window = 300 samples; at 100 Hz = 3000.  4000 is safe headroom.
_DEQUE_MAXLEN = 4000


class CSIDetector:
    """Amplitude-variance presence and motion detector with time-based windows."""

    def __init__(self):
        # Each entry: (timestamp: float, amplitudes: np.ndarray)
        self.window: deque[tuple[float, np.ndarray]] = deque(maxlen=_DEQUE_MAXLEN)
        self.baseline: np.ndarray | None = None
        self.calibrating = True
        self._calibration_count = 0
        self._null_mask: np.ndarray | None = None
        # Inter-packet interval tracker for sample rate estimation
        self._last_sample_time: float | None = None
        self._rate_intervals: deque[float] = deque(maxlen=20)

    def _estimate_sample_rate(self) -> float:
        """Return rolling-average sample rate in Hz (0.0 if not yet measured)."""
        if len(self._rate_intervals) < 2:
            return 0.0
        avg_interval = float(np.mean(list(self._rate_intervals)))
        return 1.0 / avg_interval if avg_interval > 0 else 0.0

    def _evict_old(self, now: float) -> None:
        """Drop entries older than WINDOW_DURATION_SECS."""
        cutoff = now - WINDOW_DURATION_SECS
        while self.window and self.window[0][0] < cutoff:
            self.window.popleft()

    def _samples_in_window(self, now: float, duration_secs: float) -> list[np.ndarray]:
        cutoff = now - duration_secs
        return [arr for ts, arr in self.window if ts >= cutoff]

    def update(self, amplitudes: list[float]) -> dict:
        now = time.time()
        raw = np.array(amplitudes, dtype=np.float32)

        # Build a stable subcarrier mask from the first packet, then reuse it
        if self._null_mask is None:
            self._null_mask = raw != 0.0
            log.info(
                "Null-subcarrier mask: keeping %d / %d subcarriers.",
                int(self._null_mask.sum()), len(raw),
            )
        arr = raw[self._null_mask]

        # Track inter-packet intervals for sample rate estimation
        if self._last_sample_time is not None:
            interval = now - self._last_sample_time
            if 0.0 < interval < 2.0:  # ignore outliers (reconnects, long pauses)
                self._rate_intervals.append(interval)
        self._last_sample_time = now

        # Evict stale entries, then append timestamped sample
        self._evict_old(now)
        self.window.append((now, arr))

        if self.calibrating:
            self._calibration_count += 1
            if self._calibration_count < CALIBRATION_SAMPLES:
                return {
                    "status": "calibrating",
                    "progress": self._calibration_count / CALIBRATION_SAMPLES,
                }

        if self.calibrating:
            stacked = np.stack([a for _, a in self.window])
            self.baseline = np.mean(stacked, axis=0)
            self.calibrating = False
            log.info(
                "Calibration complete. Baseline captured with %d subcarriers.",
                len(self.baseline),
            )
            return {"status": "calibrated"}

        # Reset calibration if subcarrier count changed (e.g. ESP32 reconnected)
        if arr.shape != self.baseline.shape:
            log.warning(
                "Subcarrier count changed (%d → %d), resetting calibration.",
                len(self.baseline), len(arr),
            )
            self.window.clear()
            self.baseline = None
            self.calibrating = True
            self._calibration_count = 0
            self._null_mask = None
            return {"status": "calibrating", "progress": 0.0}

        # Deviation from empty-room baseline
        deviation = arr - self.baseline
        variance = float(np.var(deviation))
        std_dev = float(np.std(deviation))

        # Effective sample rate (used for motion gating)
        sample_rate_hz = self._estimate_sample_rate()

        # Short time-window temporal variance — motion detection
        motion_samples = self._samples_in_window(now, MOTION_WINDOW_SECS)
        if len(motion_samples) >= 2:
            recent_short = np.stack(motion_samples)
            temporal_var = float(np.mean(np.var(recent_short, axis=0)))
        else:
            temporal_var = 0.0

        # Gate motion when sample rate is below threshold (unreliable at low rates).
        # When rate is unknown (0.0, not yet measured) we assume active mode and allow it.
        motion_gated = 0.0 < sample_rate_hz < MOTION_RATE_GATE_HZ

        # Long time-window temporal variance — breathing / still-presence detection
        breathing_samples = self._samples_in_window(now, BREATHING_WINDOW_SECS)
        if len(breathing_samples) >= 10:
            recent_slow = np.stack(breathing_samples)
            breathing_var = float(np.mean(np.var(recent_slow, axis=0)))
        else:
            breathing_var = 0.0

        presence = variance > PRESENCE_THRESHOLD
        motion = (not motion_gated) and (temporal_var > MOTION_THRESHOLD)

        heatmap = [round(float(abs(d)), 2) for d in deviation]

        return {
            "status": "active",
            "room": ROOM_ID,
            "presence": presence,
            "motion": motion,
            "variance": round(variance, 3),
            "std_dev": round(std_dev, 3),
            "temporal_var": round(temporal_var, 3),
            "breathing_var": round(breathing_var, 4),
            "sample_rate_hz": round(sample_rate_hz, 1),
            "motion_gated": motion_gated,
            "heatmap": heatmap,
            "timestamp": now,
        }


PUBLISH_INTERVAL = 1.0    # seconds between MQTT publishes
LEAVE_CONFIRM_SECS = 10.0 # must see no presence for this long before declaring empty
DISCONNECT_TIMEOUT = 5.0  # seconds with no UDP data before declaring room disconnected


class RoomNode:
    def __init__(self):
        self.detector = CSIDetector()
        self.mqtt_client = mqtt.Client(client_id=f"axon-room-{ROOM_ID}")
        self.running = False
        self._last_publish = 0.0
        # Pre-expire so an empty room at startup shows False immediately
        self._empty_since = time.time() - LEAVE_CONFIRM_SECS
        self._consecutive_presence = 0
        self._last_packet_time = 0.0
        self._disconnected = False

    def _default_detection_payload(self) -> dict:
        """Return a detection result with all state variables at their defaults."""
        return {
            "status": "disconnected",
            "room": ROOM_ID,
            "presence": False,
            "motion": False,
            "variance": 0.0,
            "std_dev": 0.0,
            "temporal_var": 0.0,
            "breathing_var": 0.0,
            "sample_rate_hz": 0.0,
            "motion_gated": False,
            "heatmap": [],
            "timestamp": time.time(),
        }

    def _reset_state(self):
        """Reset detector and presence tracking back to defaults."""
        self.detector = CSIDetector()
        self._empty_since = time.time() - LEAVE_CONFIRM_SECS
        self._consecutive_presence = 0
        self._disconnected = True
        log.info("Room '%s' disconnected — state reset to defaults.", ROOM_ID)

        payload = json.dumps(self._default_detection_payload())
        self.mqtt_client.publish(MQTT_TOPIC_DETECTION, payload, qos=1)

    def start(self):
        self.running = True

        try:
            self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            self.mqtt_client.loop_start()
            log.info("MQTT connected to %s:%d", MQTT_BROKER, MQTT_PORT)
        except Exception as e:
            log.warning("MQTT connection failed: %s (will retry)", e)

        if ANCHOR_MAC:
            log.info("Passive mode: accepting CSI only from anchor MAC %s", ANCHOR_MAC)
        else:
            log.info("Active mode: accepting CSI from all sources")

        if CALIBRATION_DELAY > 0:
            log.info(
                "Waiting %ds before calibration — please leave the room now.",
                CALIBRATION_DELAY,
            )
            time.sleep(CALIBRATION_DELAY)

        udp_thread = threading.Thread(target=self._udp_listener, daemon=True)
        udp_thread.start()
        watchdog_thread = threading.Thread(target=self._disconnect_watchdog, daemon=True)
        watchdog_thread.start()

        log.info("Room node '%s' started. Listening on UDP port %d", ROOM_ID, UDP_LISTEN_PORT)

        try:
            while self.running:
                time.sleep(1)
        except KeyboardInterrupt:
            self.stop()

    def stop(self):
        self.running = False
        self.mqtt_client.loop_stop()
        log.info("Room node stopped.")

    def _disconnect_watchdog(self):
        """Monitor for data timeout and reset state when the room disconnects."""
        while self.running:
            time.sleep(1)
            if (
                self._last_packet_time > 0
                and not self._disconnected
                and time.time() - self._last_packet_time > DISCONNECT_TIMEOUT
            ):
                self._reset_state()

    def _udp_listener(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", UDP_LISTEN_PORT))
        sock.settimeout(1.0)

        while self.running:
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break

            try:
                csi_packet = json.loads(data.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                log.warning("Bad packet from %s", addr)
                continue

            # MAC filter for passive/anchor mode — discard non-anchor frames
            if ANCHOR_MAC:
                src_mac = csi_packet.get("mac", "")
                if src_mac.lower() != ANCHOR_MAC.lower():
                    log.debug(
                        "Discarding frame from non-anchor MAC %s (expected %s)",
                        src_mac, ANCHOR_MAC,
                    )
                    continue

            self._last_packet_time = time.time()
            if self._disconnected:
                self._disconnected = False
                log.info("Room '%s' reconnected — recalibrating.", ROOM_ID)

            # Publish raw CSI to MQTT
            self.mqtt_client.publish(MQTT_TOPIC_RAW, data, qos=0)

            # Run detection
            amplitudes = csi_packet.get("data", [])
            if not amplitudes:
                continue

            result = self.detector.update(amplitudes)

            if result.get("status") == "active":
                now = time.time()

                if result["presence"]:
                    self._consecutive_presence += 1
                    if self._consecutive_presence >= 3:
                        self._empty_since = None
                else:
                    self._consecutive_presence = 0
                    if self._empty_since is None:
                        self._empty_since = now
                    if now - self._empty_since < LEAVE_CONFIRM_SECS:
                        result["presence"] = True

                if now - self._last_publish >= PUBLISH_INTERVAL:
                    self._last_publish = now
                    payload = json.dumps(result)
                    self.mqtt_client.publish(MQTT_TOPIC_DETECTION, payload, qos=1)
                    log.info(
                        "DETECTION [%s] presence=%s motion=%s var=%.2f breath=%.4f rate=%.1fHz%s",
                        ROOM_ID, result["presence"], result["motion"],
                        result["variance"], result["breathing_var"],
                        result["sample_rate_hz"],
                        " [motion gated]" if result["motion_gated"] else "",
                    )

        sock.close()


if __name__ == "__main__":
    ROOM_ID = os.environ.get("ROOM_ID", ROOM_ID)
    UDP_LISTEN_PORT = int(os.environ.get("UDP_LISTEN_PORT", UDP_LISTEN_PORT))
    CALIBRATION_DELAY = int(os.environ.get("CALIBRATION_DELAY", CALIBRATION_DELAY))
    ANCHOR_MAC = os.environ.get("ANCHOR_MAC", ANCHOR_MAC)

    node = RoomNode()
    node.start()
