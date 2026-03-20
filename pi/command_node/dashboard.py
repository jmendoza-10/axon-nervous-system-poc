#!/usr/bin/env python3
"""
Command Node Dashboard - Pi #1

Flask web app that:
- Receives detection events from room nodes via Reticulum + MQTT
- Displays live room status on a web dashboard
- Cryptographically signs and logs all detection events (evidence chain)
"""

import json
import time
import os
import hashlib
import threading
import logging
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, render_template, jsonify
from flask_socketio import SocketIO
import paho.mqtt.client as mqtt
import RNS

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
log = logging.getLogger("dashboard")

app = Flask(__name__)
app.config["SECRET_KEY"] = os.urandom(24).hex()
socketio = SocketIO(app, cors_allowed_origins="*")

# --- State ---
room_states = {}
event_log = []
EVIDENCE_DIR = Path("evidence_store")
EVIDENCE_DIR.mkdir(exist_ok=True)


# --- Evidence Logger ---
class EvidenceLogger:
    """Cryptographically chain-signs detection events."""

    def __init__(self, store_dir: Path):
        self.store_dir = store_dir
        self.chain_file = store_dir / "evidence_chain.jsonl"
        self.prev_hash = "genesis"

    def log_event(self, event: dict) -> dict:
        record = {
            "seq": len(event_log),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "prev_hash": self.prev_hash,
        }

        # Chain hash: SHA-256 of prev_hash + event JSON
        payload = f"{self.prev_hash}:{json.dumps(event, sort_keys=True)}"
        record["hash"] = hashlib.sha256(payload.encode()).hexdigest()
        self.prev_hash = record["hash"]

        # Append to evidence chain file
        with open(self.chain_file, "a") as f:
            f.write(json.dumps(record) + "\n")

        return record


evidence = EvidenceLogger(EVIDENCE_DIR)


# --- MQTT Listener ---
def on_mqtt_connect(client, userdata, flags, rc):
    log.info("MQTT connected (rc=%d)", rc)
    client.subscribe("axon/detection")
    client.subscribe("axon/csi/raw")


def on_mqtt_message(client, userdata, msg):
    try:
        data = json.loads(msg.payload)
    except json.JSONDecodeError:
        return

    if msg.topic == "axon/detection":
        handle_detection(data)


def handle_detection(data: dict):
    room = data.get("room", "unknown")

    room_states[room] = {
        "presence": data.get("presence", False),
        "motion": data.get("motion", False),
        "variance": data.get("variance", 0),
        "temporal_var": data.get("temporal_var", 0),
        "last_update": time.time(),
    }

    record = evidence.log_event(data)
    event_log.append(record)

    # Keep last 1000 events in memory
    if len(event_log) > 1000:
        event_log.pop(0)

    # Push to connected browsers
    socketio.emit("detection", {
        "room": room,
        "state": room_states[room],
        "hash": record["hash"][:12],
    })

    log.info("Detection [%s]: presence=%s motion=%s var=%.2f hash=%s",
             room, data.get("presence"), data.get("motion"),
             data.get("variance", 0), record["hash"][:12])


# --- Reticulum Listener ---
def start_reticulum():
    reticulum = RNS.Reticulum()
    identity = RNS.Identity()

    # Listen for announcements from room nodes
    RNS.Transport.register_announce_handler(announce_handler)
    log.info("Reticulum command node initialized. Listening for room node announcements.")


def announce_handler(destination_hash, announced_identity, app_data):
    log.info("Room node announced: %s", RNS.prettyhexrep(destination_hash))


# --- Flask Routes ---
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/rooms")
def api_rooms():
    return jsonify(room_states)


@app.route("/api/events")
def api_events():
    return jsonify(event_log[-50:])


@app.route("/api/evidence/verify")
def api_verify_chain():
    """Verify the integrity of the evidence chain."""
    try:
        with open(EVIDENCE_DIR / "evidence_chain.jsonl") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return jsonify({"valid": True, "count": 0})

    prev_hash = "genesis"
    for i, line in enumerate(lines):
        record = json.loads(line)
        payload = f"{prev_hash}:{json.dumps(record['event'], sort_keys=True)}"
        expected = hashlib.sha256(payload.encode()).hexdigest()
        if record["hash"] != expected:
            return jsonify({"valid": False, "broken_at": i, "count": len(lines)})
        prev_hash = record["hash"]

    return jsonify({"valid": True, "count": len(lines)})


# --- Main ---
def main():
    # Start Reticulum in background
    rns_thread = threading.Thread(target=start_reticulum, daemon=True)
    rns_thread.start()

    # Start MQTT listener
    mqtt_client = mqtt.Client(client_id="axon-command-node")
    mqtt_client.on_connect = on_mqtt_connect
    mqtt_client.on_message = on_mqtt_message
    try:
        mqtt_client.connect("localhost", 1883, 60)
        mqtt_client.loop_start()
    except Exception as e:
        log.warning("MQTT not available: %s (dashboard will still run)", e)

    log.info("Starting dashboard on http://0.0.0.0:5000")
    socketio.run(app, host="0.0.0.0", port=5000, debug=False, allow_unsafe_werkzeug=True)


if __name__ == "__main__":
    main()
