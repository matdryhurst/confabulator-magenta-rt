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
from collections import deque
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

TARGETS = (
    "none",
    "fractal",
    "filigree",
    "void",
    "knife",
    "organism",
    "maze",
    "seam",
    "argument",
    "haunt",
    "swarm",
    "palimpsest",
)

TARGET_DESCRIPTIONS = {
    "none": "no extra target; use the selected performance mode",
    "fractal": "chase multi-scale spectral complexity without collapsing into plain hiss",
    "filigree": "seek bright, dense, high-detail upper texture",
    "void": "seek sparse, hollow, low-energy negative space",
    "knife": "seek sharp transients and cut-up spectral edges",
    "organism": "seek slow self-similar mutation with a living internal pulse",
    "maze": "seek bounded unpredictability, changing direction before it settles",
    "seam": "play the 2-second inference boundary as a musical pulse",
    "argument": "keep the listener, prompts, text space, and codec controls in disagreement",
    "haunt": "return to half-remembered states while letting the model mutate underneath",
    "swarm": "maintain many tiny unstable changes without collapsing into one center",
    "palimpsest": "overwrite the current identity in translucent layers instead of clean jumps",
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
        target: str,
        intensity: float,
        interval: float,
        embedding_every: float,
        allow_drums: bool,
        verbose: bool,
    ) -> None:
        self.sock = sock
        self.feed = feed
        self.mode = mode
        self.target = target
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
        self.audio_history: deque[dict[str, float]] = deque(maxlen=180)
        self.target_scores: dict[str, float] = {}

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

        if self.target == "fractal":
            score += density * 0.35 + brightness * 0.22 + (1.0 - abs(0.45 - rhythm)) * 0.18
        elif self.target == "filigree":
            score += brightness * 0.55 + density * 0.25
        elif self.target == "void":
            score += (1.0 - rhythm) * 0.45 + (1.0 - density) * 0.22 + (1.0 - brightness) * 0.18
        elif self.target == "knife":
            score += brightness * 0.42 + rhythm * 0.28 + density * 0.18
        elif self.target == "organism":
            score += (1.0 - abs(0.48 - rhythm)) * 0.32 + (1.0 - abs(0.55 - density)) * 0.28
        elif self.target == "maze":
            score += density * 0.34 + (1.0 - abs(0.6 - brightness)) * 0.22 + rhythm * 0.14
        elif self.target == "seam":
            score += density * 0.24 + (1.0 - abs(0.5 - brightness)) * 0.22 + rhythm * 0.18
        elif self.target == "argument":
            score += density * 0.28 + brightness * 0.20 + abs(0.5 - rhythm) * 0.22
        elif self.target == "haunt":
            score += (1.0 - rhythm) * 0.38 + (1.0 - brightness) * 0.20 + (1.0 - abs(0.45 - density)) * 0.16
        elif self.target == "swarm":
            score += density * 0.42 + brightness * 0.24 + rhythm * 0.20
        elif self.target == "palimpsest":
            score += (1.0 - abs(0.55 - density)) * 0.30 + (1.0 - abs(0.38 - rhythm)) * 0.24
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

    def remember_audio(self, now: float, audio: dict[str, float]) -> None:
        self.audio_history.append({
            "t": now,
            "rms": clamp(audio["rms"] * 8.0),
            "brightness": clamp(audio["brightness"]),
            "roughness": clamp(audio["roughness"]),
            "onset": clamp(audio["onset"]),
            "zcr": clamp(audio["zcr"] * 12.0),
        })

    def history_values(self, key: str, horizon: float | None = None) -> list[float]:
        if not self.audio_history:
            return []
        latest = self.audio_history[-1]["t"]
        return [
            item[key]
            for item in self.audio_history
            if horizon is None or latest - item["t"] <= horizon
        ]

    @staticmethod
    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else 0.0

    @classmethod
    def std(cls, values: list[float]) -> float:
        if len(values) < 2:
            return 0.0
        avg = cls.mean(values)
        return math.sqrt(sum((value - avg) ** 2 for value in values) / len(values))

    @staticmethod
    def mean_delta(values: list[float]) -> float:
        if len(values) < 2:
            return 0.0
        return sum(abs(values[index] - values[index - 1]) for index in range(1, len(values))) / (len(values) - 1)

    @staticmethod
    def seam_pulse(elapsed: float, width: float = 0.18) -> float:
        phase = elapsed % 2.0
        distance = min(phase, 2.0 - phase)
        return clamp(1.0 - distance / max(0.01, width))

    def audio_targets(self) -> dict[str, float]:
        if len(self.audio_history) < 4:
            return {
                "energy": 0.0,
                "brightness": 0.0,
                "roughness": 0.0,
                "transient": 0.0,
                "complexity": 0.0,
                "stability": 0.0,
                "void": 0.0,
            }

        bright_short = self.history_values("brightness", 4.0)
        bright_long = self.history_values("brightness", 22.0)
        rough_short = self.history_values("roughness", 4.0)
        rough_long = self.history_values("roughness", 22.0)
        onset_short = self.history_values("onset", 4.0)
        onset_long = self.history_values("onset", 22.0)
        zcr_short = self.history_values("zcr", 4.0)
        energy_short = self.history_values("rms", 4.0)
        energy_long = self.history_values("rms", 22.0)

        micro_motion = (
            self.mean_delta(bright_short)
            + self.mean_delta(rough_short)
            + self.mean_delta(zcr_short)
        ) / 3.0
        macro_motion = (
            self.std(bright_long)
            + self.std(rough_long)
            + self.std(onset_long)
        ) / 3.0
        brightness = self.mean(bright_short)
        roughness = self.mean(rough_short)
        transient = self.mean(onset_short)
        energy = self.mean(energy_short)
        low_energy = 1.0 - self.mean(energy_long)

        # A compact proxy for "interesting spectrogram": changing at fast and
        # slow rates, bright/rough enough to have features, but not just maxed.
        whiteness_penalty = max(0.0, brightness - 0.86) * 0.45 + max(0.0, energy - 0.88) * 0.35
        complexity = clamp((micro_motion * 3.1 + macro_motion * 2.4 + roughness * 0.28 + transient * 0.18) - whiteness_penalty)
        stability = clamp(1.0 - (micro_motion * 3.0 + self.std(energy_long) * 1.6))
        void = clamp(low_energy * 0.8 + (1.0 - transient) * 0.2)

        return {
            "energy": clamp(energy),
            "brightness": clamp(brightness),
            "roughness": clamp(roughness),
            "transient": clamp(transient),
            "complexity": complexity,
            "stability": stability,
            "void": void,
        }

    def target_pressure(self, name: str, score: float) -> float:
        if self.target != name:
            return 0.0
        return clamp(1.0 - score)

    @staticmethod
    def add_values(values: dict[str, float], additions: dict[str, float]) -> None:
        for key, amount in additions.items():
            values[key] = values.get(key, 0.0) + amount

    def apply_target_controls(
        self,
        rvq: dict[str, float],
        damage: dict[str, float],
        text_lab: dict[str, float],
        *,
        slow: float,
        wobble: float,
    ) -> None:
        scores = self.audio_targets()
        self.target_scores = scores
        if self.target == "none":
            return

        intensity = self.intensity
        fractal = self.target_pressure("fractal", scores["complexity"])
        filigree = self.target_pressure("filigree", (scores["brightness"] + scores["roughness"]) * 0.5)
        void = self.target_pressure("void", scores["void"])
        knife = self.target_pressure("knife", (scores["transient"] + scores["brightness"]) * 0.5)
        organism = self.target_pressure("organism", (scores["stability"] + scores["complexity"] * 0.65) * 0.5)
        maze = self.target_pressure("maze", (scores["complexity"] * 0.7 + (1.0 - scores["stability"]) * 0.3))
        elapsed = time.monotonic() - self.start_time
        seam = self.target_pressure("seam", scores["complexity"] * 0.45 + scores["transient"] * 0.35)
        argument = self.target_pressure("argument", (1.0 - scores["stability"]) * 0.55 + scores["complexity"] * 0.25)
        haunt = self.target_pressure("haunt", scores["stability"] * 0.45 + scores["void"] * 0.35)
        swarm = self.target_pressure("swarm", scores["complexity"] * 0.55 + scores["transient"] * 0.25)
        palimpsest = self.target_pressure("palimpsest", scores["stability"] * 0.35 + scores["complexity"] * 0.35)

        if fractal:
            self.add_values(rvq, {
                "rvqForce": 0.10 * fractal,
                "rvqSweep": (0.20 + slow * 0.16) * fractal,
                "rvqStride": (0.18 + wobble * 0.18) * fractal,
                "rvqJitter": 0.14 * fractal,
                "rvqFine": 0.13 * fractal,
                "rvqMemory": 0.10 * fractal,
            })
            self.add_values(damage, {
                "comb": 0.18 * fractal,
                "harmonics": 0.16 * fractal,
                "ring": 0.07 * fractal,
                "noise": -0.05 * fractal,
            })
            self.add_values(text_lab, {
                "scan": 0.18 * fractal,
                "morph": 0.14 * fractal,
                "warp": 0.08 * fractal,
            })

        if filigree:
            self.add_values(rvq, {
                "rvqFine": 0.24 * filigree,
                "rvqJitter": 0.12 * filigree,
                "rvqCoarse": -0.06 * filigree,
                "rvqHold": -0.04 * filigree,
            })
            self.add_values(damage, {
                "harmonics": 0.24 * filigree,
                "ring": 0.15 * filigree,
                "comb": 0.08 * filigree,
                "body": -0.08 * filigree,
                "noise": -0.04 * filigree,
            })
            self.add_values(text_lab, {"scan": 0.20 * filigree, "scramble": 0.06 * filigree})

        if void:
            self.add_values(rvq, {
                "rvqForce": -0.08 * void,
                "rvqMemory": 0.26 * void,
                "rvqHold": 0.22 * void,
                "rvqBreathe": 0.18 * void,
                "rvqCoarse": 0.09 * void,
                "rvqFine": -0.06 * void,
            })
            self.add_values(damage, {
                "body": 0.28 * void,
                "smear": 0.18 * void,
                "comb": 0.12 * void,
                "drive": -0.08 * void,
                "crush": -0.08 * void,
                "noise": -0.08 * void,
            })
            self.add_values(text_lab, {"gravity": 0.18 * void, "scramble": -0.05 * void})

        if knife:
            self.add_values(rvq, {
                "rvqForce": 0.16 * knife,
                "rvqCoarse": 0.10 * knife,
                "rvqFine": 0.12 * knife,
                "rvqJitter": 0.18 * knife,
                "rvqHold": -0.08 * knife,
                "rvqMemory": -0.06 * knife,
            })
            self.add_values(damage, {
                "fold": 0.18 * knife,
                "ring": 0.22 * knife,
                "stutter": 0.18 * knife,
                "smear": -0.06 * knife,
                "harmonics": 0.14 * knife,
                "noise": -0.03 * knife,
            })
            self.add_values(text_lab, {"scramble": 0.12 * knife, "scan": 0.12 * knife})

        if organism:
            pulse = (math.sin((time.monotonic() - self.start_time) * (0.11 + intensity * 0.04)) + 1.0) * 0.5
            self.add_values(rvq, {
                "rvqBreathe": (0.24 + pulse * 0.16) * organism,
                "rvqMemory": 0.24 * organism,
                "rvqSweep": 0.10 * organism,
                "rvqJitter": 0.06 * organism,
                "rvqStride": 0.08 * organism,
            })
            self.add_values(damage, {
                "comb": 0.12 * organism,
                "smear": 0.12 * organism,
                "harmonics": 0.10 * organism,
                "noise": -0.06 * organism,
            })
            self.add_values(text_lab, {"morph": 0.20 * organism, "gravity": 0.12 * organism})

        if maze:
            turn = 1.0 if int((time.monotonic() - self.start_time) / 5.0) % 2 == 0 else -1.0
            self.add_values(rvq, {
                "rvqForce": 0.10 * maze,
                "rvqSweep": (0.24 if turn > 0 else -0.05) * maze,
                "rvqInvert": (0.18 if turn > 0 else 0.06) * maze,
                "rvqStride": (0.22 if turn < 0 else 0.08) * maze,
                "rvqJitter": 0.15 * maze,
                "rvqMemory": -0.04 * maze,
            })
            self.add_values(damage, {
                "fold": 0.12 * maze,
                "comb": 0.16 * maze,
                "stutter": 0.10 * maze,
                "pitch": 0.08 * maze,
                "noise": -0.04 * maze,
            })
            self.add_values(text_lab, {
                "warp": 0.14 * maze,
                "oppose": 0.12 * maze,
                "scan": 0.12 * maze,
            })

        if seam:
            pulse = self.seam_pulse(elapsed)
            pre_echo = self.seam_pulse(elapsed + 0.18, width=0.24) * 0.55
            seam_amount = seam * max(pulse, pre_echo)
            self.add_values(rvq, {
                "rvqForce": 0.08 * seam + 0.24 * seam_amount,
                "rvqCoarse": 0.20 * seam_amount,
                "rvqFine": -0.04 * seam + 0.08 * pulse,
                "rvqHold": 0.18 * pre_echo,
                "rvqInvert": 0.18 * seam_amount,
                "rvqStride": 0.22 * seam_amount,
                "rvqMemory": -0.08 * seam_amount,
            })
            self.add_values(damage, {
                "stutter": 0.30 * seam_amount,
                "comb": 0.18 * seam,
                "pitch": 0.10 * seam_amount,
                "ring": 0.12 * pulse,
                "noise": -0.06 * seam,
            })
            self.add_values(text_lab, {
                "oppose": 0.20 * seam_amount,
                "scan": 0.14 * seam,
                "scramble": 0.10 * seam_amount,
            })

        if argument:
            self.add_values(rvq, {
                "rvqForce": 0.12 * argument,
                "rvqCoarse": 0.16 * argument,
                "rvqFine": 0.18 * argument,
                "rvqInvert": 0.28 * argument,
                "rvqJitter": 0.16 * argument,
                "rvqMemory": -0.12 * argument,
                "rvqHold": -0.08 * argument,
            })
            self.add_values(damage, {
                "fold": 0.16 * argument,
                "ring": 0.18 * argument,
                "pitch": 0.14 * argument,
                "comb": 0.10 * argument,
                "noise": -0.05 * argument,
            })
            self.add_values(text_lab, {
                "oppose": 0.38 * argument,
                "scramble": 0.16 * argument,
                "warp": 0.16 * argument,
                "gravity": -0.08 * argument,
            })

        if haunt:
            ghost = (math.sin(elapsed * 0.17) + 1.0) * 0.5
            self.add_values(rvq, {
                "rvqBreathe": (0.22 + ghost * 0.12) * haunt,
                "rvqMemory": 0.34 * haunt,
                "rvqHold": 0.24 * haunt,
                "rvqSweep": 0.08 * haunt,
                "rvqFine": -0.04 * haunt,
                "rvqJitter": 0.05 * haunt,
            })
            self.add_values(damage, {
                "smear": 0.22 * haunt,
                "body": 0.18 * haunt,
                "comb": 0.16 * haunt,
                "harmonics": 0.08 * haunt,
                "noise": -0.08 * haunt,
            })
            self.add_values(text_lab, {
                "morph": 0.24 * haunt,
                "gravity": 0.16 * haunt,
                "warp": 0.08 * haunt,
            })

        if swarm:
            swarm_lfo = (math.sin(elapsed * 1.73) + 1.0) * 0.5
            self.add_values(rvq, {
                "rvqForce": 0.12 * swarm,
                "rvqFine": 0.24 * swarm,
                "rvqJitter": (0.20 + swarm_lfo * 0.10) * swarm,
                "rvqStride": 0.20 * swarm,
                "rvqSweep": 0.16 * swarm,
                "rvqCoarse": -0.05 * swarm,
                "rvqHold": -0.07 * swarm,
            })
            self.add_values(damage, {
                "harmonics": 0.20 * swarm,
                "ring": 0.16 * swarm,
                "stutter": 0.12 * swarm,
                "comb": 0.08 * swarm,
                "noise": -0.04 * swarm,
            })
            self.add_values(text_lab, {
                "scan": 0.24 * swarm,
                "scramble": 0.16 * swarm,
                "morph": 0.08 * swarm,
            })

        if palimpsest:
            layer = (math.sin(elapsed * 0.09) + 1.0) * 0.5
            self.add_values(rvq, {
                "rvqMemory": 0.30 * palimpsest,
                "rvqHold": 0.18 * palimpsest,
                "rvqSweep": (0.14 + layer * 0.12) * palimpsest,
                "rvqBreathe": 0.12 * palimpsest,
                "rvqFine": 0.08 * palimpsest,
                "rvqInvert": 0.08 * palimpsest,
            })
            self.add_values(damage, {
                "smear": 0.20 * palimpsest,
                "comb": 0.18 * palimpsest,
                "body": 0.10 * palimpsest,
                "pitch": 0.08 * palimpsest,
                "noise": -0.07 * palimpsest,
            })
            self.add_values(text_lab, {
                "morph": 0.28 * palimpsest,
                "warp": 0.16 * palimpsest,
                "oppose": 0.10 * palimpsest,
                "gravity": 0.08 * palimpsest,
            })

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
        if self.target == "argument":
            speed *= 1.42
            radius_x *= 1.22
            radius_y *= 1.30
        elif self.target == "haunt":
            speed *= 0.58
            radius_x *= 0.70
            radius_y *= 0.78
        elif self.target == "swarm":
            speed *= 1.85
            radius_x *= 0.82
            radius_y *= 0.88
        elif self.target == "palimpsest":
            speed *= 0.72
            radius_x *= 0.94
            radius_y *= 0.92
        listener_x = clamp(620.0 + math.cos(elapsed * speed) * radius_x * 0.36, 80.0, 1120.0)
        listener_y = clamp(225.0 + math.sin(elapsed * speed * 0.73) * radius_y * 0.45, 55.0, 430.0)
        if self.target == "seam":
            pulse = self.seam_pulse(elapsed)
            listener_x += math.sin(elapsed * math.pi) * 115.0 * pulse
            listener_y += math.cos(elapsed * math.pi * 0.5) * 55.0 * pulse
        elif self.target == "argument":
            listener_x = clamp(620.0 - math.cos(elapsed * speed * 0.91) * radius_x * 0.46, 80.0, 1120.0)
            listener_y = clamp(225.0 - math.sin(elapsed * speed * 1.11) * radius_y * 0.55, 55.0, 430.0)
        elif self.target == "swarm":
            listener_x += math.sin(elapsed * 2.9) * 32.0 * self.intensity
            listener_y += math.cos(elapsed * 2.3) * 22.0 * self.intensity
        elif self.target == "palimpsest":
            listener_x = listener_x * 0.84 + lx * 0.16
            listener_y = listener_y * 0.84 + ly * 0.16
        listener_x = clamp(listener_x, 80.0, 1120.0)
        listener_y = clamp(listener_y, 55.0, 430.0)
        self.send({"type": "moveListener", "x": round(listener_x, 2), "y": round(listener_y, 2)})

        ids = self.prompt_ids()
        if not ids and not force:
            return
        for index, prompt_id in enumerate(ids[:3]):
            angle = elapsed * speed * (0.55 + index * 0.11) + index * math.tau / 3.0
            wobble = math.sin(elapsed * 0.19 + index) * 34.0 * self.intensity
            if self.target == "argument":
                angle += math.pi * (1 if index % 2 == 0 else -1)
                wobble += math.sin(elapsed * 0.83 + index * 1.7) * 38.0 * self.intensity
            elif self.target == "haunt":
                wobble *= 0.38
            elif self.target == "swarm":
                wobble += math.sin(elapsed * (1.7 + index * 0.33)) * 44.0 * self.intensity
            elif self.target == "palimpsest":
                angle += math.sin(elapsed * 0.07 + index) * 0.55
            elif self.target == "seam":
                wobble += self.seam_pulse(elapsed + index * 0.12) * 58.0 * self.intensity
            x = clamp(lx + math.cos(angle) * (radius_x + wobble), 50.0, 1190.0)
            y = clamp(ly + math.sin(angle * 1.17) * (radius_y + wobble * 0.35), 45.0, 455.0)
            if self.target == "palimpsest":
                x = x * 0.78 + (lx + (index - 1) * 72.0) * 0.22
                y = y * 0.78 + (ly + math.sin(elapsed * 0.11 + index) * 42.0) * 0.22
            self.send({"type": "movePrompt", "promptId": prompt_id, "x": round(x, 2), "y": round(y, 2)})

    def set_controls(self, now: float, *, force: bool = False) -> None:
        audio = self.current_audio()
        self.remember_audio(now, audio)
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

        text_lab = {
            "warp": 0.08 + intensity * 0.22 + slow * 0.10,
            "scramble": 0.02 + (rough if self.mode == "noise" else onset) * 0.18,
            "morph": 0.16 + slow * 0.32,
            "oppose": 0.02 + wobble * 0.16,
            "scan": 0.08 + bright * 0.24,
            "gravity": 0.15 + (1.0 - energy) * 0.30,
        }
        self.apply_target_controls(rvq, damage, text_lab, slow=slow, wobble=wobble)

        self.send({"type": "setRvq", "values": {key: round(clamp(value), 3) for key, value in rvq.items()}})
        self.send({"type": "setDamage", "values": {key: round(clamp(value), 3) for key, value in damage.items()}})
        self.send({
            "type": "setTextLab",
            "values": {key: round(clamp(value), 3) for key, value in text_lab.items()},
        })

        if now - self.last_log > 4.0:
            self.last_log = now
            target_note = ""
            if self.target != "none" and self.target_scores:
                target_note = f" target={self.target} complexity={self.target_scores['complexity']:.2f}"
            print(
                f"{self.mode} rms={audio['rms']:.3f} peak={audio['peak']:.2f} "
                f"bright={bright:.2f} rough={rough:.2f}{target_note} sent={self.sent}",
                file=sys.stderr,
            )

    def maybe_major_gesture(self, now: float) -> None:
        audio = self.current_audio()
        if self.rescue_kick_enabled and audio["rms"] < 0.002 and now - self.last_quiet_kick > 8.0:
            self.last_quiet_kick = now
            self.send({"type": "play", "value": True})
            self.send({"type": "kick"})

        embedding_interval = self.embedding_every
        if self.target in {"argument", "swarm", "seam"}:
            embedding_interval *= 0.72
        elif self.target in {"haunt", "palimpsest"}:
            embedding_interval *= 1.35

        if now - self.last_embedding_change > embedding_interval:
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

            if self.target == "seam":
                self.send({"type": "macro", "name": random.choice(["shred", "ghost"])})
            elif self.target == "argument":
                self.send({"type": "setPerformance", "values": {
                    "drift": round(random.uniform(0.58, 0.90), 3),
                    "snapback": round(random.uniform(0.08, 0.42), 3),
                }})
                if random.random() < 0.55:
                    self.send({"type": "jolt"})
            elif self.target == "haunt":
                self.send({"type": "macro", "name": "ghost"})
            elif self.target == "swarm":
                self.send({"type": "macro", "name": random.choice(["metal", "shred"])})
            elif self.target == "palimpsest":
                self.send({"type": "macro", "name": random.choice(["melt", "ghost"])})

    def run(self, *, take_seconds: float | None, record: bool, start_playing: bool, recording_window: int) -> str:
        self.rescue_kick_enabled = start_playing
        if not self.wait_for_state():
            print("warning: connected, but no state arrived yet", file=sys.stderr)
        if not self.wait_for_catalog():
            print("warning: no embedding catalog received yet; performing with current prompts", file=sys.stderr)
        self.bootstrap(start_playing=start_playing, record=record, recording_window=recording_window)
        print(
            f"performing mode={self.mode} target={self.target} intensity={self.intensity:.2f}; press Ctrl-C to stop",
            file=sys.stderr,
        )
        deadline = time.monotonic() + take_seconds if take_seconds else None
        while self.feed.connected:
            now = time.monotonic()
            if deadline and now >= deadline:
                return "complete"
            self.place_prompts(now)
            self.set_controls(now)
            self.maybe_major_gesture(now)
            time.sleep(self.interval)
        return "disconnected"


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
    parser.add_argument(
        "--target",
        choices=TARGETS,
        default="none",
        help="Unusual listening objective. Use --list-targets to see the full set.",
    )
    parser.add_argument("--list-targets", action="store_true", help="Print target descriptions and exit.")
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
    parser.add_argument("--no-reconnect", action="store_true", help="Exit instead of reconnecting if the socket drops.")
    args = parser.parse_args()

    if args.list_targets:
        for name in TARGETS:
            print(f"{name:9} {TARGET_DESCRIPTIONS[name]}")
        return 0

    if args.seed is not None:
        random.seed(args.seed)

    deadline = time.monotonic() + args.take if args.take else None
    should_continue = True
    started_recording = False

    def connect_once() -> tuple[socket.socket, SharedFeed, ConfabulatorPerformer]:
        sock = socket.create_connection((args.host, args.port), timeout=5.0)
        feed = SharedFeed()
        print(f"connected to CONFABULATOR at {args.host}:{args.port}", file=sys.stderr)
        threading.Thread(target=reader, args=(sock, feed, args.raw), daemon=True).start()
        performer = ConfabulatorPerformer(
            sock,
            feed,
            mode=args.mode,
            target=args.target,
            intensity=args.intensity,
            interval=args.interval,
            embedding_every=args.embedding_every,
            allow_drums=args.allow_drums,
            verbose=args.verbose,
        )
        return sock, feed, performer

    try:
        while should_continue:
            remaining = max(0.0, deadline - time.monotonic()) if deadline else None
            if deadline and remaining <= 0:
                break
            sock, _feed, performer = connect_once()
            with sock:
                try:
                    outcome = performer.run(
                        take_seconds=remaining,
                        record=args.record,
                        start_playing=not args.no_start,
                        recording_window=args.recording_window,
                    )
                    started_recording = started_recording or args.record
                except KeyboardInterrupt:
                    print("\nstopping performer", file=sys.stderr)
                    should_continue = False
                    break
            if outcome == "complete":
                break
            if args.no_reconnect:
                print("socket disconnected; exiting because --no-reconnect was set", file=sys.stderr)
                break
            print("socket disconnected; reconnecting in 1 second", file=sys.stderr)
            time.sleep(1.0)

        if started_recording:
            for attempt in range(4):
                try:
                    sock, _feed, performer = connect_once()
                    with sock:
                        time.sleep(0.25)
                        performer.send({"type": "recordStop"})
                    break
                except OSError:
                    if attempt == 3:
                        raise
                    time.sleep(1.0)
    except ConnectionRefusedError:
        print("Could not connect. Open CONFABULATOR first, then run this script again.", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"Socket error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
