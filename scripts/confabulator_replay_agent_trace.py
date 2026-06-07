#!/usr/bin/env python3
"""Replay a CONFABULATOR recipe's agent trace as a timed performance score."""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path
from typing import Any


RECORDER_COMMANDS = {"recordStart", "recordStop", "captureLast", "setRecordingWindow"}
INTERNAL_KEYS = {"__receivedAt"}


def load_recipe(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        raise SystemExit(f"Recipe not found: {path}")
    except json.JSONDecodeError as error:
        raise SystemExit(f"Could not parse recipe JSON: {error}") from error


def agent_events(recipe: dict[str, Any]) -> list[dict[str, Any]]:
    patch = recipe.get("patch") if isinstance(recipe, dict) else {}
    performance = (patch or {}).get("agent_performance") if isinstance(patch, dict) else {}
    events = (performance or {}).get("events") if isinstance(performance, dict) else []
    if not isinstance(events, list):
        return []
    return [event for event in events if isinstance(event, dict)]


def clean_payload(payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None
    cleaned = {key: value for key, value in payload.items() if key not in INTERNAL_KEYS}
    if not isinstance(cleaned.get("type"), str):
        return None
    cleaned["source"] = "confabulator_trace_replay"
    return cleaned


def replayable_events(
    events: list[dict[str, Any]],
    *,
    include_recorder: bool,
    start_at: float | None,
    end_at: float | None,
) -> list[tuple[float, dict[str, Any]]]:
    replay: list[tuple[float, dict[str, Any]]] = []
    for event in events:
        if event.get("direction") != "in":
            continue
        t = event.get("t")
        if not isinstance(t, (int, float)):
            continue
        if start_at is not None and t < start_at:
            continue
        if end_at is not None and t > end_at:
            continue
        payload = clean_payload(event.get("payload"))
        if not payload:
            continue
        if not include_recorder and payload.get("type") in RECORDER_COMMANDS:
            continue
        replay.append((float(t), payload))
    replay.sort(key=lambda item: item[0])
    return replay


def send(sock: socket.socket, command: dict[str, Any]) -> None:
    line = json.dumps(command, separators=(",", ":"), ensure_ascii=True) + "\n"
    sock.sendall(line.encode("utf-8"))


def connect(host: str, port: int) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=5.0)
    sock.settimeout(0.25)
    try:
        sock.recv(8192)
    except OSError:
        pass
    sock.settimeout(None)
    return sock


def print_summary(replay: list[tuple[float, dict[str, Any]]]) -> None:
    if not replay:
        print("No replayable agent input events found.")
        return
    counts: dict[str, int] = {}
    for _, payload in replay:
        kind = str(payload.get("type"))
        counts[kind] = counts.get(kind, 0) + 1
    first = replay[0][0]
    last = replay[-1][0]
    print(f"events: {len(replay)}")
    print(f"trace window: {first:.3f}s -> {last:.3f}s ({last - first:.3f}s normalized)")
    print("commands:")
    for kind, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        print(f"  {kind}: {count}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Replay a CONFABULATOR agent trace from a recipe file.")
    parser.add_argument("recipe", type=Path, help=".confab.json recipe containing patch.agent_performance.events")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47873)
    parser.add_argument("--speed", type=float, default=1.0, help="Playback speed. 2.0 is twice as fast.")
    parser.add_argument("--start-at", type=float, help="Original trace time to start at, in seconds.")
    parser.add_argument("--end-at", type=float, help="Original trace time to stop at, in seconds.")
    parser.add_argument("--max-events", type=int, help="Replay only the first N selected events.")
    parser.add_argument("--summary", action="store_true", help="Print a summary and exit.")
    parser.add_argument("--dry-run", action="store_true", help="Print the timed commands without sending them.")
    parser.add_argument("--include-recorder", action="store_true", help="Replay original recorder commands too.")
    parser.add_argument("--record", action="store_true", help="Record this replay as a fresh CONFABULATOR take.")
    parser.add_argument("--no-start", action="store_true", help="Do not send play/kick before replay.")
    args = parser.parse_args()

    if args.speed <= 0:
        raise SystemExit("--speed must be greater than zero")

    recipe = load_recipe(args.recipe.expanduser())
    replay = replayable_events(
        agent_events(recipe),
        include_recorder=args.include_recorder,
        start_at=args.start_at,
        end_at=args.end_at,
    )
    if args.max_events is not None:
        replay = replay[: max(0, args.max_events)]

    if args.summary:
        print_summary(replay)
        return 0

    if not replay:
        raise SystemExit("No replayable agent input events found.")

    print_summary(replay)
    base_t = replay[0][0]
    started = time.monotonic()

    sock: socket.socket | None = None
    if not args.dry_run:
        sock = connect(args.host, args.port)
        print(f"connected to CONFABULATOR at {args.host}:{args.port}", file=sys.stderr)
        if not args.no_start:
            send(sock, {"type": "play", "value": True, "source": "confabulator_trace_replay"})
            send(sock, {"type": "kick", "source": "confabulator_trace_replay"})
        if args.record:
            send(sock, {"type": "recordStart", "source": "confabulator_trace_replay"})

    try:
        for index, (event_t, payload) in enumerate(replay, start=1):
            target_elapsed = (event_t - base_t) / args.speed
            wait = started + target_elapsed - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            if args.dry_run:
                print(f"{target_elapsed:9.3f}s {json.dumps(payload, ensure_ascii=True)}")
            else:
                assert sock is not None
                send(sock, payload)
                if index == 1 or index % 100 == 0 or index == len(replay):
                    print(f"sent {index}/{len(replay)} at +{target_elapsed:.1f}s", file=sys.stderr)
    except KeyboardInterrupt:
        print("\nreplay interrupted", file=sys.stderr)
    finally:
        if sock is not None:
            if args.record:
                time.sleep(0.25)
                send(sock, {"type": "recordStop", "source": "confabulator_trace_replay"})
            sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
