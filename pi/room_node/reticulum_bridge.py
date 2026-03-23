#!/usr/bin/env python3
"""
Reticulum Bridge - Room Node

Subscribes to local MQTT detection events and forwards them
over the Reticulum mesh network to the command node.
"""

import json
import logging
import os

import RNS
import paho.mqtt.client as mqtt

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
log = logging.getLogger("reticulum_bridge")

MQTT_BROKER = "localhost"
MQTT_PORT = 1883
MQTT_TOPIC_DETECTION = "axon/detection"

APP_NAME = "axon"
ASPECT = "detection"

ROOM_ID = os.environ.get("ROOM_ID", "room_a")


class CommandAnnounceHandler:
    """RNS requires an object with received_announce() — plain callables are ignored."""
    aspect_filter = None

    def __init__(self, bridge):
        self.bridge = bridge

    def received_announce(self, destination_hash, announced_identity, app_data):
        log.info("Command node announced: %s", RNS.prettyhexrep(destination_hash))
        self.bridge.command_hash = destination_hash


class ReticulumBridge:
    def __init__(self, room_id: str = "room_a"):
        self.room_id = room_id
        self.reticulum = None
        self.identity = None
        self.destination = None
        self.command_hash = None  # discovered via announce

    def start(self):
        self.reticulum = RNS.Reticulum()
        self.identity = RNS.Identity()

        # Create our own destination so the command node can discover us
        self.destination = RNS.Destination(
            self.identity,
            RNS.Destination.IN,
            RNS.Destination.SINGLE,
            APP_NAME,
            ASPECT,
            self.room_id,
        )
        self.destination.announce()
        log.info(
            "Reticulum destination announced: %s.%s.%s [%s]",
            APP_NAME, ASPECT, self.room_id,
            RNS.prettyhexrep(self.destination.hash),
        )

        # Discover the command node destination via its announcement
        RNS.Transport.register_announce_handler(CommandAnnounceHandler(self))
        log.info("Waiting for command node announcement...")

        # Connect to local MQTT and forward detections
        mqtt_client = mqtt.Client(client_id=f"rns-bridge-{self.room_id}")
        mqtt_client.on_connect = self._on_mqtt_connect
        mqtt_client.on_message = self._on_mqtt_message
        mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)

        log.info("Reticulum bridge running for room '%s'", self.room_id)
        mqtt_client.loop_forever()

    def _on_mqtt_connect(self, client, userdata, flags, rc):
        log.info("MQTT connected (rc=%d), subscribing to %s", rc, MQTT_TOPIC_DETECTION)
        client.subscribe(MQTT_TOPIC_DETECTION)

    def _on_mqtt_message(self, client, userdata, msg):
        try:
            detection = json.loads(msg.payload)
        except json.JSONDecodeError:
            return

        if self.command_hash is None:
            log.warning("Command node not yet discovered — dropping detection for room '%s'", self.room_id)
            return

        command_identity = RNS.Identity.recall(self.command_hash)
        if command_identity is None:
            log.warning("Command identity not in cache — dropping detection")
            return

        dest = RNS.Destination(
            command_identity,
            RNS.Destination.OUT,
            RNS.Destination.SINGLE,
            "axon",
            "command",
        )
        # Strip heatmap before sending — raw floats exceed Reticulum's 500-byte MTU
        slim = {k: v for k, v in detection.items() if k != "heatmap"}
        packet_data = json.dumps(slim).encode("utf-8")
        RNS.Packet(dest, packet_data).send()

        # Send heatmap as a separate packet with values quantized to 0–15 integers
        # 64 values × ~2 bytes + JSON wrapper ≈ 200 bytes, well under MTU
        if "heatmap" in detection:
            heatmap_q = [min(15, round(v)) for v in detection["heatmap"]]
            hm_data = json.dumps({
                "type": "heatmap",
                "room": detection.get("room"),
                "values": heatmap_q,
            }).encode("utf-8")
            RNS.Packet(dest, hm_data).send()

        log.debug("Forwarded detection over Reticulum: %s", detection.get("room"))


if __name__ == "__main__":
    bridge = ReticulumBridge(room_id=ROOM_ID)
    bridge.start()
