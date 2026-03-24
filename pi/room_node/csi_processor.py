#!/usr/bin/env python3
"""
CSI Processor - Room Node (Pi #2 / Pi #3)

Receives raw CSI JSON data from ESP32-RX via UDP,
runs presence/motion detection, and publishes results
to MQTT and Reticulum.
"""

import json
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
ROOM_ID = "room_a"  # Override via env or config

# Detection parameters
WINDOW_SIZE = 500         # CSI samples in sliding window (~5s at 100Hz)
MOTION_THRESHOLD = 3.0    # Temporal variance threshold for motion (frame-to-frame change rate)
MOTION_WINDOW = 5         # Samples for motion detection (~50ms at 100Hz — fast response)
PRESENCE_THRESHOLD = 8.0  # Variance threshold for presence (deviation from baseline)
BREATHING_WINDOW = 400    # Samples for slow temporal variance (~4s, captures breathing)
BREATHING_THRESHOLD = 1.5 # Temporal variance threshold for breathing / still presence
CALIBRATION_DELAY = 20    # Seconds to wait before starting calibration (time to leave room)


class CSIDetector:
    """Simple amplitude-variance based presence and motion detector."""

    def __init__(self, window_size: int = WINDOW_SIZE):
        self.window = deque(maxlen=window_size)
        self.baseline = None
        self.calibrating = True
        self.calibration_samples = 200
        self._calibration_count = 0  # separate counter, not capped by window_size
        self._null_mask = None  # boolean mask to strip DC-null / guard subcarriers

    @staticmethod
    def _strip_null_subcarriers(arr: np.ndarray) -> np.ndarray:
        """Remove DC-null and guard subcarriers (always zero in 802.11 OFDM)."""
        mask = arr != 0.0
        # On first packet the mask tells us which are live; for subsequent
        # packets we keep the same indices so shapes stay consistent.
        return arr[mask] if mask.any() else arr

    def update(self, amplitudes: list[float]) -> dict:
        raw = np.array(amplitudes, dtype=np.float32)

        # Build a stable mask from the first packet, then reuse it
        if self._null_mask is None:
            self._null_mask = raw != 0.0
            log.info(
                "Null-subcarrier mask: keeping %d / %d subcarriers.",
                int(self._null_mask.sum()), len(raw),
            )
        arr = raw[self._null_mask]

        self.window.append(arr)

        if self.calibrating:
            self._calibration_count += 1
            if self._calibration_count < self.calibration_samples:
                return {"status": "calibrating", "progress": self._calibration_count / self.calibration_samples}

        if self.calibrating:
            stacked = np.stack(list(self.window))
            self.baseline = np.mean(stacked, axis=0)
            self.calibrating = False
            log.info("Calibration complete. Baseline captured with %d subcarriers.", len(self.baseline))
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
            return {"status": "calibrating", "progress": 0.0}

        # Compute deviation from baseline
        deviation = arr - self.baseline
        variance = np.var(deviation)
        std_dev = np.std(deviation)

        # Short temporal variance (motion detection — last MOTION_WINDOW samples ~50ms)
        if len(self.window) >= MOTION_WINDOW:
            recent_short = np.stack(list(self.window)[-MOTION_WINDOW:])
            temporal_var = np.mean(np.var(recent_short, axis=0))
        else:
            temporal_var = 0.0

        # Long temporal variance (breathing detection — last ~4s captures respiration cycles)
        n_slow = min(BREATHING_WINDOW, len(self.window))
        if n_slow >= 50:
            recent_slow = np.stack(list(self.window)[-n_slow:])
            breathing_var = np.mean(np.var(recent_slow, axis=0))
        else:
            breathing_var = 0.0

        # Presence: sustained deviation from empty-room baseline (unchanged)
        presence = bool(variance > PRESENCE_THRESHOLD)
        # Motion: rapid frame-to-frame change rate over last ~50ms
        motion = bool(temporal_var > MOTION_THRESHOLD)

        # Per-subcarrier absolute deviation for heatmap (only live subcarriers)
        heatmap = [round(float(abs(d)), 2) for d in deviation]

        return {
            "status": "active",
            "room": ROOM_ID,
            "presence": presence,
            "motion": motion,
            "variance": round(float(variance), 3),
            "std_dev": round(float(std_dev), 3),
            "temporal_var": round(float(temporal_var), 3),
            "breathing_var": round(float(breathing_var), 4),
            "heatmap": heatmap,
            "timestamp": time.time(),
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
        self._consecutive_presence = 0  # require sustained signal before resetting leave timer
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

        # Publish the cleared state so downstream consumers know immediately
        payload = json.dumps(self._default_detection_payload())
        self.mqtt_client.publish(MQTT_TOPIC_DETECTION, payload, qos=1)

    def start(self):
        self.running = True

        # Connect MQTT
        try:
            self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            self.mqtt_client.loop_start()
            log.info("MQTT connected to %s:%d", MQTT_BROKER, MQTT_PORT)
        except Exception as e:
            log.warning("MQTT connection failed: %s (will retry)", e)

        # Give time to vacate the room before calibration starts
        if CALIBRATION_DELAY > 0:
            log.info("Waiting %ds before calibration — please leave the room now.", CALIBRATION_DELAY)
            time.sleep(CALIBRATION_DELAY)

        # Start UDP listener and disconnect watchdog
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
                    # Only reset leave timer after 3 consecutive True readings (~30ms)
                    # prevents single noisy packets from resetting the countdown
                    if self._consecutive_presence >= 3:
                        self._empty_since = None
                else:
                    self._consecutive_presence = 0
                    if self._empty_since is None:
                        self._empty_since = now
                    # Stay "present" until absence is confirmed for LEAVE_CONFIRM_SECS
                    if now - self._empty_since < LEAVE_CONFIRM_SECS:
                        result["presence"] = True

                # Rate-limit MQTT publishes to PUBLISH_INTERVAL
                if now - self._last_publish >= PUBLISH_INTERVAL:
                    self._last_publish = now
                    payload = json.dumps(result)
                    self.mqtt_client.publish(MQTT_TOPIC_DETECTION, payload, qos=1)
                    log.info(
                        "DETECTION [%s] presence=%s motion=%s var=%.2f breath=%.4f",
                        ROOM_ID, result["presence"], result["motion"],
                        result["variance"], result["breathing_var"],
                    )

        sock.close()


if __name__ == "__main__":
    import os

    ROOM_ID = os.environ.get("ROOM_ID", ROOM_ID)
    UDP_LISTEN_PORT = int(os.environ.get("UDP_LISTEN_PORT", UDP_LISTEN_PORT))
    CALIBRATION_DELAY = int(os.environ.get("CALIBRATION_DELAY", CALIBRATION_DELAY))

    node = RoomNode()
    node.start()
