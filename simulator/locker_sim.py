"""
Locker simulator for the Smart Community Locker System.

Stands in for the ESP32 cabinet controller. It speaks exactly the MQTT contract the real
firmware will speak, so the app and the backend cannot tell the difference:

    subscribe  cmd/{station}/open    {"tokenId", "compartmentId"}
    subscribe  cmd/{station}/deny    {"tokenId"}
    publish    evt/{station}/scan    {"payload"}            <- a code was presented
    publish    evt/{station}/status  {"compartmentId","state"}

Two behaviours matter and are both real here, not faked:

  * Idempotency. MQTT QoS 1 delivers at least once, so the same open command can arrive
    twice. Seen token IDs are remembered and a repeat is ignored. Evaluation criterion E6
    tests exactly this.

  * Offline mode. With --offline the simulator refuses cloud commands and accepts a cached
    PIN locally, queueing the audit event until it is back online. That is requirement QR4.

Usage
-----
    pip install paho-mqtt python-dotenv
    python locker_sim.py --station STATION-01

    # present a code (simulates someone scanning at the cabinet)
    python locker_sim.py --station STATION-01 --scan "<payload>"

    # offline test for E6
    python locker_sim.py --station STATION-01 --offline
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
from collections import deque
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # dotenv is optional
    pass


# --------------------------------------------------------------------------- config


def env(name: str, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if value is None:
        sys.exit(f"Missing environment variable {name}. Copy .env.example to .env.")
    return value


HOST = env("MQTT_HOST", "localhost")
PORT = int(env("MQTT_PORT", "1883"))
USER = os.getenv("MQTT_USER")
PASS = os.getenv("MQTT_PASS")
USE_TLS = PORT == 8883

# How long the solenoid is held open, and how long we pretend the door stays ajar.
UNLOCK_SECONDS = 1.0
DOOR_OPEN_SECONDS = 4.0


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(msg: str) -> None:
    print(f"[{now()}] {msg}", flush=True)


# --------------------------------------------------------------------------- simulator


class LockerSimulator:
    def __init__(self, station: str, offline: bool = False, cached_pins: set[str] | None = None):
        self.station = station
        self.offline = offline
        self.cached_pins = cached_pins or {"4821"}  # normally a salted hash; plain for the demo
        self.handled_tokens: set[str] = set()
        self.pending_events: deque[dict] = deque()  # audit events queued while offline
        self.client = mqtt.Client(client_id=f"locker-{station}", protocol=mqtt.MQTTv311)

        if USER:
            self.client.username_pw_set(USER, PASS)
        if USE_TLS:
            self.client.tls_set(cert_reqs=ssl.CERT_REQUIRED)

        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message

    # -- topics -------------------------------------------------------------

    def topic(self, kind: str, leaf: str) -> str:
        return f"{kind}/{self.station}/{leaf}"

    # -- connection ---------------------------------------------------------

    def _on_connect(self, client, userdata, flags, rc):
        if rc != 0:
            log(f"connect failed, rc={rc}")
            return
        log(f"connected to {HOST}:{PORT} as station {self.station}")
        client.subscribe(self.topic("cmd", "#"), qos=1)
        self._flush_pending()

    def _flush_pending(self) -> None:
        """Publish audit events that were queued while the link was down (QR4)."""
        while self.pending_events:
            event = self.pending_events.popleft()
            self.client.publish(self.topic("evt", "status"), json.dumps(event), qos=1)
            log(f"flushed queued event {event}")

    # -- inbound commands ---------------------------------------------------

    def _on_message(self, client, userdata, msg):
        leaf = msg.topic.rsplit("/", 1)[-1]
        try:
            payload = json.loads(msg.payload.decode())
        except json.JSONDecodeError:
            log(f"ignored malformed message on {msg.topic}")
            return

        if self.offline:
            log(f"offline: ignoring cloud command on {msg.topic}")
            return

        if leaf == "open":
            self._handle_open(payload)
        elif leaf == "deny":
            log(f"denied by server: token {payload.get('tokenId')} -> LED + buzzer")
        else:
            log(f"unknown command {leaf}")

    def _handle_open(self, payload: dict) -> None:
        token_id = payload.get("tokenId")
        compartment = payload.get("compartmentId")

        # Idempotency. QoS 1 can deliver the same command twice (E6).
        if token_id in self.handled_tokens:
            log(f"duplicate command for token {token_id} -> ignored, lock NOT re-opened")
            return
        self.handled_tokens.add(token_id)

        log(f"opening compartment {compartment} for token {token_id}")
        time.sleep(UNLOCK_SECONDS)  # energise the solenoid
        self._publish_status(compartment, "DOOR_OPEN")

        time.sleep(DOOR_OPEN_SECONDS)  # user takes or leaves the item
        self._publish_status(compartment, "DOOR_CLOSED")

    def _publish_status(self, compartment: str | None, state: str) -> None:
        event = {"compartmentId": compartment, "state": state, "at": now()}
        if self.offline:
            self.pending_events.append(event)
            log(f"offline: queued {state} for later")
            return
        self.client.publish(self.topic("evt", "status"), json.dumps(event), qos=1)
        log(f"published {state} for {compartment}")

    # -- outbound: presenting a code ----------------------------------------

    def present(self, payload: str) -> None:
        """A user holds their QR code up to the scanner.

        The cabinet does not validate it. It forwards the payload and lets the server
        decide. That is the rule from Milestone 1, section 4.1.
        """
        if self.offline:
            self._offline_pin(payload)
            return
        body = json.dumps({"payload": payload, "at": now()})
        self.client.publish(self.topic("evt", "scan"), body, qos=1)
        log("scan published, waiting for the server to decide")

    def _offline_pin(self, entered: str) -> None:
        """QR4: with no network the controller falls back to a cached PIN."""
        if entered in self.cached_pins:
            log("offline PIN accepted locally")
            self._publish_status("OFFLINE", "DOOR_OPEN")
        else:
            log("offline PIN rejected")

    # -- lifecycle ----------------------------------------------------------

    def run(self, scan: str | None = None) -> None:
        self.client.connect(HOST, PORT, keepalive=60)
        self.client.loop_start()
        time.sleep(1)

        if scan:
            self.present(scan)
            time.sleep(8)
        else:
            mode = "OFFLINE" if self.offline else "online"
            log(f"listening in {mode} mode. Ctrl+C to stop.")
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                log("stopping")

        self.client.loop_stop()
        self.client.disconnect()


# --------------------------------------------------------------------------- cli


def main() -> None:
    parser = argparse.ArgumentParser(description="SCLS locker simulator")
    parser.add_argument("--station", required=True, help="station id, e.g. STATION-01")
    parser.add_argument("--scan", help="present this code payload, then exit")
    parser.add_argument("--offline", action="store_true", help="simulate a network outage")
    args = parser.parse_args()

    LockerSimulator(station=args.station, offline=args.offline).run(scan=args.scan)


if __name__ == "__main__":
    main()
