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
WINDOW_SIZE = 50          # CSI samples in sliding window
MOTION_THRESHOLD = 3.0    # Std-dev threshold for motion detection
PRESENCE_THRESHOLD = 1.5  # Variance threshold for presence


class CSIDetector:
    """Simple amplitude-variance based presence and motion detector."""

    def __init__(self, window_size: int = WINDOW_SIZE):
        self.window = deque(maxlen=window_size)
        self.baseline = None
        self.calibrating = True
        self.calibration_samples = 200

    def update(self, amplitudes: list[float]) -> dict:
        arr = np.array(amplitudes, dtype=np.float32)
        self.window.append(arr)

        if len(self.window) < self.calibration_samples and self.calibrating:
            return {"status": "calibrating", "progress": len(self.window) / self.calibration_samples}

        if self.calibrating:
            stacked = np.stack(list(self.window))
            self.baseline = np.mean(stacked, axis=0)
            self.calibrating = False
            log.info("Calibration complete. Baseline captured with %d subcarriers.", len(self.baseline))
            return {"status": "calibrated"}

        # Compute deviation from baseline
        deviation = arr - self.baseline
        variance = np.var(deviation)
        std_dev = np.std(deviation)

        # Temporal variance across window
        if len(self.window) >= 10:
            recent = np.stack(list(self.window)[-10:])
            temporal_var = np.mean(np.var(recent, axis=0))
        else:
            temporal_var = 0.0

        presence = bool(variance > PRESENCE_THRESHOLD)
        motion = bool(std_dev > MOTION_THRESHOLD)

        return {
            "status": "active",
            "room": ROOM_ID,
            "presence": presence,
            "motion": motion,
            "variance": round(float(variance), 3),
            "std_dev": round(float(std_dev), 3),
            "temporal_var": round(float(temporal_var), 3),
            "timestamp": time.time(),
        }


class RoomNode:
    def __init__(self):
        self.detector = CSIDetector()
        self.mqtt_client = mqtt.Client(client_id=f"axon-room-{ROOM_ID}")
        self.running = False

    def start(self):
        self.running = True

        # Connect MQTT
        try:
            self.mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            self.mqtt_client.loop_start()
            log.info("MQTT connected to %s:%d", MQTT_BROKER, MQTT_PORT)
        except Exception as e:
            log.warning("MQTT connection failed: %s (will retry)", e)

        # Start UDP listener
        udp_thread = threading.Thread(target=self._udp_listener, daemon=True)
        udp_thread.start()

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

            # Publish raw CSI to MQTT
            self.mqtt_client.publish(MQTT_TOPIC_RAW, data, qos=0)

            # Run detection
            amplitudes = csi_packet.get("data", [])
            if not amplitudes:
                continue

            result = self.detector.update(amplitudes)

            if result.get("status") == "active":
                payload = json.dumps(result)
                self.mqtt_client.publish(MQTT_TOPIC_DETECTION, payload, qos=1)

                if result["presence"]:
                    log.info(
                        "DETECTION [%s] presence=%s motion=%s var=%.2f",
                        ROOM_ID, result["presence"], result["motion"], result["variance"],
                    )

        sock.close()


if __name__ == "__main__":
    import os

    ROOM_ID = os.environ.get("ROOM_ID", ROOM_ID)
    UDP_LISTEN_PORT = int(os.environ.get("UDP_LISTEN_PORT", UDP_LISTEN_PORT))

    node = RoomNode()
    node.start()
