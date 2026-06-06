#!/usr/bin/env python3
"""Tiny JSONL client for the CONFABULATOR agent performance socket.

Run CONFABULATOR, then run this script. It prints incoming state/catalog
messages and lets you type JSON commands on stdin.
"""

from __future__ import annotations

import argparse
import json
import random
import socket
import sys
import threading
import time
from typing import Any


def compact(message: dict[str, Any]) -> str:
    kind = message.get("type", "message")
    if kind == "state":
        audio = message.get("audio", {})
        ui = message.get("ui", {})
        surface = ui.get("prompt_surface", {}) if isinstance(ui, dict) else {}
        prompts = surface.get("prompts", []) if isinstance(surface, dict) else []
        return (
            f"state peak={audio.get('peak', 0):.3f} "
            f"rms={audio.get('rms', 0):.3f} "
            f"bright={audio.get('brightness', 0):.2f} "
            f"onset={audio.get('onset', 0):.2f} "
            f"prompts={len(prompts)}"
        )
    if kind == "catalog":
        banks = message.get("catalog", {}).get("embeddings", {}).get("banks", [])
        return f"catalog banks={len(banks)}"
    return json.dumps(message, ensure_ascii=True)[:500]


def reader(sock: socket.socket, raw: bool) -> None:
    file = sock.makefile("r", encoding="utf-8")
    for line in file:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            print(line.rstrip())
            continue
        print(json.dumps(message, ensure_ascii=True) if raw else compact(message), flush=True)


def send(sock: socket.socket, command: dict[str, Any]) -> None:
    sock.sendall((json.dumps(command, separators=(",", ":")) + "\n").encode("utf-8"))


def demo(sock: socket.socket) -> None:
    macros = ["metal", "melt", "ghost", "shred"]
    while True:
        time.sleep(random.uniform(3.0, 6.0))
        send(sock, {"type": "moveListener", "x": random.uniform(120, 900), "y": random.uniform(100, 380)})
        send(sock, {"type": "setRvq", "values": {
            "rvqForce": random.uniform(0.05, 0.45),
            "rvqBreathe": random.random(),
            "rvqMemory": random.uniform(0.0, 0.65),
            "rvqJitter": random.uniform(0.0, 0.55),
        }})
        if random.random() < 0.35:
            send(sock, {"type": "macro", "name": random.choice(macros)})


def main() -> int:
    parser = argparse.ArgumentParser(description="Connect to CONFABULATOR's local agent socket.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47873)
    parser.add_argument("--raw", action="store_true", help="Print full incoming JSON lines.")
    parser.add_argument("--demo", action="store_true", help="Send a simple autonomous demo performance.")
    args = parser.parse_args()

    with socket.create_connection((args.host, args.port)) as sock:
        print(f"connected to {args.host}:{args.port}", file=sys.stderr)
        threading.Thread(target=reader, args=(sock, args.raw), daemon=True).start()
        if args.demo:
            threading.Thread(target=demo, args=(sock,), daemon=True).start()
        print("type JSON commands, for example: {\"type\":\"macro\",\"name\":\"melt\"}", file=sys.stderr)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                command = json.loads(line)
            except json.JSONDecodeError as error:
                print(f"invalid JSON: {error}", file=sys.stderr)
                continue
            send(sock, command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
