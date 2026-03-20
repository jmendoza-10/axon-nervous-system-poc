#!/usr/bin/env python3
"""
Reticulum Bridge - Room Node

Subscribes to local MQTT detection events and forwards them
over the Reticulum mesh network to the command node.
"""

import json
import time
import logging

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


class ReticulumBridge:
    def __init__(self, room_id: str = "room_a"):
        self.room_id = room_id
        self.reticulum = None
        self.identity = None
        self.destination = None

    def start(self):
        # Initialize Reticulum
        self.reticulum = RNS.Reticulum()
        self.identity = RNS.Identity()

        # Create a destination that the command node can discover
        self.destination = RNS.Destination(
            self.identity,
            RNS.Destination.IN,
            RNS.Destination.SINGLE,
            APP_NAME,
            ASPECT,
            self.room_id,
        )

        # Announce ourselves on the mesh
        self.destination.announce()
        log.info(
            "Reticulum destination announced: %s.%s.%s [%s]",
            APP_NAME, ASPECT, self.room_id,
            RNS.prettyhexrep(self.destination.hash),
        )

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

        # Send over Reticulum as a broadcast packet
        packet_data = json.dumps(detection).encode("utf-8")
        packet = RNS.Packet(self.destination, packet_data)
        packet.send()

        log.debug("Forwarded detection over Reticulum: %s", detection.get("room"))


if __name__ == "__main__":
    import os

    room_id = os.environ.get("ROOM_ID", "room_a")
    bridge = ReticulumBridge(room_id=room_id)
    bridge.start()
