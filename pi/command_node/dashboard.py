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
DASHBOARD_PRESENCE_HOLD = 8.0  # seconds to hold presence on dashboard before showing empty
EVIDENCE_DIR = Path("evidence_store")
EVIDENCE_DIR.mkdir(exist_ok=True)


# --- Evidence Logger ---
class EvidenceLogger:
    """Cryptographically chain-signs detection events."""

    def __init__(self, store_dir: Path):
        self.store_dir = store_dir
        self.chain_file = store_dir / "evidence_chain.jsonl"
        self.prev_hash = self._load_last_hash()

    def _load_last_hash(self) -> str:
        try:
            with open(self.chain_file, "r") as f:
                last_line = None
                for line in f:
                    line = line.strip()
                    if line:
                        last_line = line
                if last_line is None:
                    return "genesis"
                return json.loads(last_line)["hash"]
        except (FileNotFoundError, KeyError, json.JSONDecodeError):
            return "genesis"

    def log_event(self, event: dict) -> dict:
        record = {
            "seq": len(event_log),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "prev_hash": self.prev_hash,
        }

        # Normalize event through JSON round-trip so the hash matches
        # what verify computes after reading the record back from disk
        # (avoids float representation drift, e.g. 3.0 vs 3)
        normalized_event = json.loads(json.dumps(event, sort_keys=True))
        record["event"] = normalized_event

        # Chain hash: SHA-256 of prev_hash + event JSON
        payload = f"{self.prev_hash}:{json.dumps(normalized_event, sort_keys=True)}"
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

    now = time.time()
    existing = room_states.get(room, {})

    # Extend hold on positive detection; preserve hold if still within window
    if data.get("presence"):
        presence_until = now + DASHBOARD_PRESENCE_HOLD
    else:
        presence_until = existing.get("presence_until", 0)

    room_states[room] = {
        "presence": now < presence_until,
        "motion": data.get("motion", False),
        "variance": data.get("variance", 0),
        "temporal_var": data.get("temporal_var", 0),
        "last_update": now,
        "presence_until": presence_until,
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

    if "heatmap" in data:
        socketio.emit("heatmap", {
            "room": room,
            "values": data["heatmap"],
        })

    log.info("Detection [%s]: presence=%s motion=%s var=%.2f hash=%s",
             room, data.get("presence"), data.get("motion"),
             data.get("variance", 0), record["hash"][:12])


# --- Reticulum Listener ---
class RoomAnnounceHandler:
    """RNS requires an object with received_announce() — plain callables are ignored."""
    aspect_filter = None

    def received_announce(self, destination_hash, announced_identity, app_data):
        log.info("Room node announced: %s", RNS.prettyhexrep(destination_hash))


def start_reticulum():
    reticulum = RNS.Reticulum()
    identity = RNS.Identity()

    # Create command node destination — room bridges send packets here
    destination = RNS.Destination(
        identity,
        RNS.Destination.IN,
        RNS.Destination.SINGLE,
        "axon",
        "command",
    )
    destination.set_packet_callback(on_rns_packet)
    destination.announce()
    log.info(
        "Reticulum command node ready. Hash: %s",
        RNS.prettyhexrep(destination.hash),
    )

    # Also log when room nodes announce themselves
    RNS.Transport.register_announce_handler(RoomAnnounceHandler())

    # Re-announce periodically so room nodes that start later can discover us
    def _reannounce():
        while True:
            time.sleep(60)
            destination.announce()
            log.debug("Re-announced command node destination")

    threading.Thread(target=_reannounce, daemon=True).start()


def on_rns_packet(message, packet):
    try:
        data = json.loads(message.decode("utf-8"))
        if data.get("type") == "heatmap":
            socketio.emit("heatmap", {"room": data["room"], "values": data["values"]})
        else:
            handle_detection(data)
    except Exception as e:
        log.warning("Failed to decode Reticulum packet: %s", e)


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


@app.route("/api/topology")
def api_topology():
    """Return node connectivity status for the topology map."""
    now = time.time()
    STALE_THRESHOLD = 10.0  # seconds without update = offline
    nodes = {}
    for room, state in room_states.items():
        last = state.get("last_update", 0)
        nodes[room] = {
            "online": (now - last) < STALE_THRESHOLD,
            "last_seen": last,
            "age": round(now - last, 1),
        }
    return jsonify(nodes)


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
    # Reticulum must init on the main thread (it sets signal handlers)
    start_reticulum()

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
