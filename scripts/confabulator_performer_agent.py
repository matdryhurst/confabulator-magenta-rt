#!/usr/bin/env python3
"""Autonomous real-time performer for CONFABULATOR.

Run CONFABULATOR first, then run this script. It connects to the local
performance socket, listens to compact audio/UI state, and sends continuous
gestures back to the instrument.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Any


HOST = "127.0.0.1"
PORT = 47873

NO_DRUM_WORDS = (
    "drum",
    "drums",
    "percussion",
    "perc",
    "kick",
    "snare",
    "hihat",
    "hi-hat",
    "hat",
    "cymbal",
    "beat",
    "breakbeat",
    "loop",
)

MODE_WORDS = {
    "drift": ("bow", "string", "tone", "slow", "sustain", "glass", "harmonic", "warm"),
    "xray": ("raw", "glass", "dense", "pulse", "bow", "metal", "harmonic", "scrape"),
    "noise": ("raw", "dense", "metal", "bright", "pulse", "scrape", "crush", "rough"),
    "duet": ("bow", "glass", "tone", "pulse", "string", "harmonic", "bright", "slow"),
}


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def fnum(value: Any, default: float = 0.0) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(number):
        return default
    return number


def compact_json(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, separators=(",", ":"), ensure_ascii=True) + "\n").encode("utf-8")


@dataclass
class SharedFeed:
    lock: threading.Lock = field(default_factory=threading.Lock)
    hello: dict[str, Any] = field(default_factory=dict)
    state: dict[str, Any] = field(default_factory=dict)
    catalog: dict[str, Any] = field(default_factory=dict)
    last_ack: dict[str, Any] = field(default_factory=dict)
    message_count: int = 0
    connected: bool = True

    def update(self, message: dict[str, Any]) -> None:
        with self.lock:
            self.message_count += 1
            kind = message.get("type")
            if kind == "hello":
                self.hello = message
            elif kind == "state":
                self.state = message
            elif kind == "catalog":
                self.catalog = message.get("catalog", {})
            elif kind == "ack":
                self.last_ack = message

    def snapshot(self) -> tuple[dict[str, Any], dict[str, Any]]:
        with self.lock:
            return dict(self.state), dict(self.catalog)


class ConfabulatorPerformer:
    def __init__(
        self,
        sock: socket.socket,
        feed: SharedFeed,
        *,
        mode: str,
        intensity: float,
        interval: float,
        embedding_every: float,
        allow_drums: bool,
        verbose: bool,
    ) -> None:
        self.sock = sock
        self.feed = feed
        self.mode = mode
        self.intensity = clamp(intensity)
        self.interval = max(0.08, interval)
        self.embedding_every = max(8.0, embedding_every)
        self.allow_drums = allow_drums
        self.verbose = verbose
        self.start_time = time.monotonic()
        self.last_embedding_change = 0.0
        self.last_major_gesture = 0.0
        self.last_quiet_kick = 0.0
        self.last_log = 0.0
        self.send_lock = threading.Lock()
        self.sent = 0
        self.rescue_kick_enabled = True

    def send(self, payload: dict[str, Any]) -> None:
        payload.setdefault("source", "confabulator_performer_agent")
        with self.send_lock:
            self.sock.sendall(compact_json(payload))
        self.sent += 1
        if self.verbose and payload.get("type") not in {"moveListener", "movePrompt"}:
            print("send", json.dumps(payload, ensure_ascii=True), file=sys.stderr)

    def wait_for_state(self, timeout: float = 8.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state, _ = self.feed.snapshot()
            if state:
                return True
            time.sleep(0.05)
        return False

    def wait_for_catalog(self, timeout: float = 3.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            _, catalog = self.feed.snapshot()
            embeddings = catalog.get("embeddings", {}) if isinstance(catalog, dict) else {}
            banks = embeddings.get("banks", []) if isinstance(embeddings, dict) else []
            if banks:
                return True
            time.sleep(0.05)
        return False

    def flatten_embeddings(self, catalog: dict[str, Any]) -> list[dict[str, Any]]:
        embeddings = catalog.get("embeddings", {}) if isinstance(catalog, dict) else {}
        banks = embeddings.get("banks", []) if isinstance(embeddings, dict) else []
        items: list[dict[str, Any]] = []
        for bank in banks:
            if not isinstance(bank, dict):
                continue
            bank_label = str(bank.get("label", ""))
            bank_id = str(bank.get("id", ""))
            for item in bank.get("items", []) or []:
                if not isinstance(item, dict):
                    continue
                label = str(item.get("label", ""))
                haystack = f"{bank_id} {bank_label} {label}".lower()
                if not self.allow_drums and any(word in haystack for word in NO_DRUM_WORDS):
                    continue
                merged = dict(item)
                merged["_bank_id"] = bank_id
                merged["_bank_label"] = bank_label
                items.append(merged)
        return items

    def score_embedding(self, item: dict[str, Any]) -> float:
        text = " ".join(
            str(item.get(key, ""))
            for key in ("id", "label", "bank", "_bank_id", "_bank_label", "features", "styleTokens")
        ).lower()
        words = MODE_WORDS.get(self.mode, MODE_WORDS["xray"])
        score = sum(1.0 for word in words if word in text)
        brightness = fnum(item.get("brightness"), 0.5)
        density = fnum(item.get("density"), 0.5)
        rhythm = fnum(item.get("rhythm"), 0.25)
        if self.mode == "drift":
            score += (1.0 - rhythm) * 0.6 + (1.0 - density) * 0.3
        elif self.mode == "noise":
            score += brightness * 0.4 + density * 0.5
        elif self.mode == "xray":
            score += density * 0.35 + (1.0 - rhythm) * 0.25
        else:
            score += abs(0.55 - brightness) * -0.3 + (1.0 - rhythm) * 0.25
        return score + random.random() * 0.65

    def choose_embeddings(self, count: int = 3) -> list[str]:
        _, catalog = self.feed.snapshot()
        items = self.flatten_embeddings(catalog)
        if not items:
            return []
        ranked = sorted(items, key=self.score_embedding, reverse=True)
        top_pool = ranked[: max(count * 8, min(32, len(ranked)))]
        random.shuffle(top_pool)
        picked: list[str] = []
        for item in sorted(top_pool, key=self.score_embedding, reverse=True):
            item_id = str(item.get("id", ""))
            if item_id and item_id not in picked:
                picked.append(item_id)
            if len(picked) >= count:
                break
        return picked

    def bootstrap(self, *, start_playing: bool, record: bool, recording_window: int) -> None:
        if start_playing:
            self.send({"type": "play", "value": True})
            self.send({"type": "kick"})
        self.send({"type": "setRecordingWindow", "seconds": recording_window})
        self.send({
            "type": "setCore",
            "values": {
                "temperature": round(0.9 + self.intensity * 0.45, 3),
                "topk": int(55 + self.intensity * 80),
                "cfgmusiccoca": round(2.05 + self.intensity * 1.35, 3),
                "cfgnotes": round(1.1 + self.intensity * 1.15, 3),
                "cfgdrums": 0.0,
                "drumless": True,
                "buffersize": 1,
                "seedrotation": round(0.15 + self.intensity * 0.55, 3),
            },
        })
        self.send({"type": "setPerformance", "values": {"drift": 0.4 + self.intensity * 0.25, "snapback": 0.35}})
        self.set_initial_embeddings()
        self.place_prompts(time.monotonic(), force=True)
        self.set_controls(time.monotonic(), force=True)
        if record:
            self.send({"type": "recordStart"})

    def set_initial_embeddings(self) -> None:
        picked = self.choose_embeddings(3)
        if picked:
            self.send({"type": "setEmbeddings", "items": picked})
            self.last_embedding_change = time.monotonic()
            print(f"selected embeddings: {', '.join(picked[:3])}", file=sys.stderr)

    def current_audio(self) -> dict[str, float]:
        state, _ = self.feed.snapshot()
        audio = state.get("audio", {}) if isinstance(state, dict) else {}
        return {
            "peak": fnum(audio.get("peak")),
            "rms": fnum(audio.get("rms")),
            "brightness": fnum(audio.get("brightness"), 0.4),
            "roughness": fnum(audio.get("roughness"), 0.3),
            "onset": fnum(audio.get("onset")),
            "zcr": fnum(audio.get("zeroCrossingRate")),
        }

    def surface(self) -> dict[str, Any]:
        state, _ = self.feed.snapshot()
        ui = state.get("ui", {}) if isinstance(state, dict) else {}
        surface = ui.get("prompt_surface", {}) if isinstance(ui, dict) else {}
        return surface if isinstance(surface, dict) else {}

    def prompt_ids(self) -> list[int]:
        prompts = self.surface().get("prompts", [])
        ids: list[int] = []
        for prompt in prompts if isinstance(prompts, list) else []:
            if isinstance(prompt, dict):
                try:
                    ids.append(int(prompt.get("id")))
                except (TypeError, ValueError):
                    pass
        return ids[:4]

    def place_prompts(self, now: float, *, force: bool = False) -> None:
        surface = self.surface()
        listener = surface.get("listener", {}) if isinstance(surface, dict) else {}
        lx = fnum(listener.get("x"), 620.0)
        ly = fnum(listener.get("y"), 210.0)
        elapsed = now - self.start_time
        speed = 0.085 + self.intensity * 0.08
        radius_x = 240.0 + self.intensity * 130.0
        radius_y = 105.0 + self.intensity * 80.0
        if self.mode == "noise":
            radius_x *= 1.18
            radius_y *= 1.25
        listener_x = clamp(620.0 + math.cos(elapsed * speed) * radius_x * 0.36, 80.0, 1120.0)
        listener_y = clamp(225.0 + math.sin(elapsed * speed * 0.73) * radius_y * 0.45, 55.0, 430.0)
        self.send({"type": "moveListener", "x": round(listener_x, 2), "y": round(listener_y, 2)})

        ids = self.prompt_ids()
        if not ids and not force:
            return
        for index, prompt_id in enumerate(ids[:3]):
            angle = elapsed * speed * (0.55 + index * 0.11) + index * math.tau / 3.0
            wobble = math.sin(elapsed * 0.19 + index) * 34.0 * self.intensity
            x = clamp(lx + math.cos(angle) * (radius_x + wobble), 50.0, 1190.0)
            y = clamp(ly + math.sin(angle * 1.17) * (radius_y + wobble * 0.35), 45.0, 455.0)
            self.send({"type": "movePrompt", "promptId": prompt_id, "x": round(x, 2), "y": round(y, 2)})

    def set_controls(self, now: float, *, force: bool = False) -> None:
        audio = self.current_audio()
        energy = clamp(audio["rms"] * 7.0)
        bright = clamp(audio["brightness"])
        rough = clamp(audio["roughness"])
        onset = clamp(audio["onset"])
        elapsed = now - self.start_time
        slow = (math.sin(elapsed * 0.23) + 1.0) * 0.5
        wobble = (math.sin(elapsed * 0.71) + 1.0) * 0.5
        intensity = self.intensity

        if self.mode == "drift":
            rvq = {
                "rvqForce": 0.08 + intensity * 0.18 + slow * 0.08,
                "rvqBreathe": 0.32 + intensity * 0.36,
                "rvqMemory": 0.42 + slow * 0.36,
                "rvqCoarse": 0.05 + intensity * 0.10,
                "rvqFine": 0.12 + wobble * 0.28,
                "rvqSweep": 0.10 + slow * 0.22,
                "rvqHold": 0.10 + (1.0 - energy) * 0.22,
                "rvqInvert": 0.02 + intensity * 0.06,
                "rvqJitter": 0.04 + onset * 0.16,
                "rvqStride": 0.10 + wobble * 0.24,
            }
            damage = {
                "wet": 0.18 + intensity * 0.18,
                "drive": 0.04 + rough * 0.08,
                "fold": 0.02 + slow * 0.06,
                "crush": 0.02 + intensity * 0.05,
                "ring": 0.03 + bright * 0.07,
                "comb": 0.08 + slow * 0.20,
                "body": 0.14 + (1.0 - bright) * 0.16,
                "smear": 0.10 + intensity * 0.22,
                "stutter": 0.02 + onset * 0.08,
                "pitch": 0.04 + slow * 0.08,
                "harmonics": 0.12 + bright * 0.16,
                "noise": 0.0,
            }
        elif self.mode == "noise":
            rvq = {
                "rvqForce": 0.24 + intensity * 0.42 + onset * 0.08,
                "rvqBreathe": 0.18 + wobble * 0.42,
                "rvqMemory": 0.12 + slow * 0.45,
                "rvqCoarse": 0.16 + (1.0 - bright) * 0.22,
                "rvqFine": 0.24 + rough * 0.35,
                "rvqSweep": 0.24 + slow * 0.52,
                "rvqHold": 0.02 + onset * 0.16,
                "rvqInvert": 0.08 + wobble * 0.42,
                "rvqJitter": 0.12 + rough * 0.42,
                "rvqStride": 0.22 + slow * 0.50,
            }
            damage = {
                "wet": 0.30 + intensity * 0.38,
                "drive": 0.10 + intensity * 0.25,
                "fold": 0.08 + wobble * 0.30,
                "crush": 0.06 + rough * 0.24,
                "ring": 0.10 + bright * 0.32,
                "comb": 0.18 + slow * 0.44,
                "body": 0.10 + (1.0 - bright) * 0.28,
                "smear": 0.12 + intensity * 0.32,
                "stutter": 0.04 + onset * 0.26,
                "pitch": 0.08 + slow * 0.26,
                "harmonics": 0.16 + bright * 0.38,
                "noise": 0.02 + intensity * 0.10,
            }
        elif self.mode == "duet":
            rvq = {
                "rvqForce": 0.12 + intensity * 0.24 + max(0.0, 0.35 - energy) * 0.12,
                "rvqBreathe": 0.22 + bright * 0.28,
                "rvqMemory": 0.26 + (1.0 - onset) * 0.34,
                "rvqCoarse": 0.08 + (1.0 - bright) * 0.18,
                "rvqFine": 0.14 + bright * 0.32,
                "rvqSweep": 0.10 + onset * 0.48,
                "rvqHold": 0.08 + max(0.0, 0.45 - energy) * 0.38,
                "rvqInvert": 0.02 + rough * 0.22,
                "rvqJitter": 0.04 + onset * 0.34,
                "rvqStride": 0.12 + rough * 0.34,
            }
            damage = {
                "wet": 0.20 + intensity * 0.22,
                "drive": 0.04 + energy * 0.10,
                "fold": 0.03 + rough * 0.12,
                "crush": 0.02 + rough * 0.10,
                "ring": 0.04 + bright * 0.18,
                "comb": 0.10 + slow * 0.24,
                "body": 0.12 + (1.0 - bright) * 0.22,
                "smear": 0.08 + (1.0 - onset) * 0.18,
                "stutter": 0.01 + onset * 0.12,
                "pitch": 0.05 + slow * 0.18,
                "harmonics": 0.12 + bright * 0.26,
                "noise": 0.0,
            }
        else:
            rvq = {
                "rvqForce": 0.18 + intensity * 0.30 + slow * 0.08,
                "rvqBreathe": 0.20 + slow * 0.28,
                "rvqMemory": 0.20 + wobble * 0.36,
                "rvqCoarse": 0.12 + (1.0 - bright) * 0.22,
                "rvqFine": 0.14 + bright * 0.34,
                "rvqSweep": 0.18 + slow * 0.44,
                "rvqHold": 0.08 + (1.0 - energy) * 0.22,
                "rvqInvert": 0.04 + wobble * 0.22,
                "rvqJitter": 0.06 + onset * 0.28,
                "rvqStride": 0.18 + slow * 0.38,
            }
            damage = {
                "wet": 0.18 + intensity * 0.26,
                "drive": 0.05 + rough * 0.13,
                "fold": 0.03 + wobble * 0.14,
                "crush": 0.03 + rough * 0.12,
                "ring": 0.05 + bright * 0.16,
                "comb": 0.12 + slow * 0.32,
                "body": 0.12 + (1.0 - bright) * 0.18,
                "smear": 0.08 + intensity * 0.22,
                "stutter": 0.02 + onset * 0.12,
                "pitch": 0.06 + slow * 0.16,
                "harmonics": 0.14 + bright * 0.28,
                "noise": 0.0,
            }

        if audio["peak"] > 0.88:
            rvq = {key: value * 0.72 for key, value in rvq.items()}
            damage["wet"] *= 0.75
            damage["drive"] *= 0.55
            damage["crush"] *= 0.45
            damage["noise"] = 0.0

        self.send({"type": "setRvq", "values": {key: round(clamp(value), 3) for key, value in rvq.items()}})
        self.send({"type": "setDamage", "values": {key: round(clamp(value), 3) for key, value in damage.items()}})
        self.send({
            "type": "setTextLab",
            "values": {
                "warp": round(clamp(0.08 + intensity * 0.22 + slow * 0.10), 3),
                "scramble": round(clamp(0.02 + (rough if self.mode == "noise" else onset) * 0.18), 3),
                "morph": round(clamp(0.16 + slow * 0.32), 3),
                "oppose": round(clamp(0.02 + wobble * 0.16), 3),
                "scan": round(clamp(0.08 + bright * 0.24), 3),
                "gravity": round(clamp(0.15 + (1.0 - energy) * 0.30), 3),
            },
        })

        if now - self.last_log > 4.0:
            self.last_log = now
            print(
                f"{self.mode} rms={audio['rms']:.3f} peak={audio['peak']:.2f} "
                f"bright={bright:.2f} rough={rough:.2f} sent={self.sent}",
                file=sys.stderr,
            )

    def maybe_major_gesture(self, now: float) -> None:
        audio = self.current_audio()
        if self.rescue_kick_enabled and audio["rms"] < 0.002 and now - self.last_quiet_kick > 8.0:
            self.last_quiet_kick = now
            self.send({"type": "play", "value": True})
            self.send({"type": "kick"})

        if now - self.last_embedding_change > self.embedding_every:
            picked = self.choose_embeddings(3)
            if picked:
                self.last_embedding_change = now
                self.send({"type": "setEmbeddings", "items": picked})
                print(f"changed embeddings: {', '.join(picked[:3])}", file=sys.stderr)

        if now - self.last_major_gesture > 13.0 + random.random() * 7.0:
            self.last_major_gesture = now
            if self.mode == "noise" and random.random() < 0.5:
                self.send({"type": "macro", "name": random.choice(["metal", "melt", "shred"])})
            elif self.mode == "xray" and random.random() < 0.4:
                self.send({"type": "macro", "name": random.choice(["metal", "ghost"])})
            elif self.mode == "duet" and audio["onset"] > 0.18:
                self.send({"type": "jolt"})

    def run(self, *, take_seconds: float | None, record: bool, start_playing: bool, recording_window: int) -> None:
        self.rescue_kick_enabled = start_playing
        if not self.wait_for_state():
            print("warning: connected, but no state arrived yet", file=sys.stderr)
        if not self.wait_for_catalog():
            print("warning: no embedding catalog received yet; performing with current prompts", file=sys.stderr)
        self.bootstrap(start_playing=start_playing, record=record, recording_window=recording_window)
        print(
            f"performing mode={self.mode} intensity={self.intensity:.2f}; press Ctrl-C to stop",
            file=sys.stderr,
        )
        deadline = time.monotonic() + take_seconds if take_seconds else None
        while self.feed.connected:
            now = time.monotonic()
            if deadline and now >= deadline:
                break
            self.place_prompts(now)
            self.set_controls(now)
            self.maybe_major_gesture(now)
            time.sleep(self.interval)


def reader(sock: socket.socket, feed: SharedFeed, raw: bool) -> None:
    try:
        file = sock.makefile("r", encoding="utf-8")
        for line in file:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                if raw:
                    print(line.rstrip())
                continue
            feed.update(message)
            if raw:
                print(json.dumps(message, ensure_ascii=True), flush=True)
    finally:
        feed.connected = False


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomous real-time performer for CONFABULATOR.")
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--mode", choices=("xray", "drift", "duet", "noise"), default="xray")
    parser.add_argument("--intensity", type=float, default=0.55, help="0.0 gentle, 1.0 aggressive.")
    parser.add_argument("--interval", type=float, default=0.65, help="Seconds between gesture updates.")
    parser.add_argument("--embedding-every", type=float, default=32.0, help="Seconds between embedding changes.")
    parser.add_argument("--take", type=float, help="Perform for this many seconds, then stop.")
    parser.add_argument("--record", action="store_true", help="Start CONFABULATOR recording while the agent performs.")
    parser.add_argument("--recording-window", type=int, default=60)
    parser.add_argument("--no-start", action="store_true", help="Do not send play/kick on launch.")
    parser.add_argument("--allow-drums", action="store_true", help="Allow drum/percussion embeddings.")
    parser.add_argument("--seed", type=int, help="Seed for reproducible gesture choices.")
    parser.add_argument("--raw", action="store_true", help="Print every incoming JSON message.")
    parser.add_argument("--verbose", action="store_true", help="Print outgoing non-position commands.")
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    feed = SharedFeed()
    try:
        with socket.create_connection((args.host, args.port), timeout=5.0) as sock:
            print(f"connected to CONFABULATOR at {args.host}:{args.port}", file=sys.stderr)
            thread = threading.Thread(target=reader, args=(sock, feed, args.raw), daemon=True)
            thread.start()
            performer = ConfabulatorPerformer(
                sock,
                feed,
                mode=args.mode,
                intensity=args.intensity,
                interval=args.interval,
                embedding_every=args.embedding_every,
                allow_drums=args.allow_drums,
                verbose=args.verbose,
            )
            try:
                performer.run(
                    take_seconds=args.take,
                    record=args.record,
                    start_playing=not args.no_start,
                    recording_window=args.recording_window,
                )
            except KeyboardInterrupt:
                print("\nstopping performer", file=sys.stderr)
            finally:
                if args.record:
                    performer.send({"type": "recordStop"})
    except ConnectionRefusedError:
        print("Could not connect. Open CONFABULATOR first, then run this script again.", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"Socket error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
