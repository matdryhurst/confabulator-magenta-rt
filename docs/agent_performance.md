# CONFABULATOR Agent Performance Socket

CONFABULATOR exposes a local JSON-lines socket so an AI agent can listen to the
instrument state and send performance gestures back.

The socket binds only to localhost:

```text
127.0.0.1:47873
```

This is not an internet service. It is for a local agent running on the same
machine as the instrument.

## What The Agent Can Sense

Every few frames, CONFABULATOR sends a JSON line like:

```json
{
  "type": "state",
  "audio": {
    "peak": 0.12,
    "rms": 0.04,
    "loudnessDb": -27.8,
    "brightness": 0.31,
    "roughness": 0.44,
    "zeroCrossingRate": 0.08,
    "onset": 0.2
  },
  "ui": {
    "params": {},
    "damage": {},
    "rvq": {},
    "prompt_surface": {}
  }
}
```

In plain English, the agent can hear a compact summary of the audio and see the
instrument's structured state: prompts, listener position, selected embedding,
core model settings, RVQ controls, damage controls, recorder state, and macros.

CONFABULATOR also sends a `catalog` message listing available embedding banks,
embedding IDs, control keys, RVQ keys, macros, and recorder commands.

## Commands

Send one JSON object per line.

Core model settings:

```json
{"type":"setParam","key":"temperature","value":1.2}
{"type":"setCore","values":{"temperature":1.1,"topk":80,"cfgmusiccoca":2.4}}
```

Damage:

```json
{"type":"setDamage","values":{"wet":0.6,"drive":0.2,"comb":0.7}}
```

SpectroStream RVQ:

```json
{"type":"setRvq","values":{"rvqForce":0.35,"rvqCoarse":0.2,"rvqFine":0.6}}
```

Prompt surface:

```json
{"type":"moveListener","x":500,"y":220}
{"type":"movePrompt","promptId":0,"x":180,"y":120}
{"type":"setPromptText","promptId":0,"text":"detuned bowed glass"}
```

Embeddings:

```json
{"type":"selectEmbedding","bankId":"mixed-corpus__example-id"}
{"type":"selectEmbedding","bankId":"mixed-corpus__example-id","add":true}
{"type":"setEmbeddings","items":["id-one","id-two","id-three"]}
```

Performance:

```json
{"type":"macro","name":"melt"}
{"type":"randomCore"}
{"type":"randomDamage"}
{"type":"jolt"}
{"type":"clean"}
{"type":"kick"}
```

Recording:

```json
{"type":"recordStart"}
{"type":"recordStop"}
{"type":"captureLast","seconds":30,"mode":"agent-sketch"}
{"type":"setRecordingWindow","seconds":60}
```

Transport:

```json
{"type":"play","value":true}
{"type":"togglePlay"}
```

## Quick Client

Run CONFABULATOR first, then:

```bash
python3 scripts/confabulator_agent_client.py
```

Type commands into the terminal:

```json
{"type":"macro","name":"melt"}
{"type":"setRvq","values":{"rvqForce":0.4,"rvqJitter":0.25}}
{"type":"recordStart"}
```

There is also a simple autonomous test mode:

```bash
python3 scripts/confabulator_agent_client.py --demo
```

## Autonomous Performer

For an agent that actually performs while you listen, open CONFABULATOR and run:

```bash
python3 scripts/confabulator_performer_agent.py
```

It starts playback, chooses a few embeddings from the current bank catalog,
moves the listener and prompt nodes, and continuously pushes RVQ/token-warp,
damage, text-lab, and core settings while reacting to the audio summary coming
back from the app.

Modes:

```bash
python3 scripts/confabulator_performer_agent.py --mode xray
python3 scripts/confabulator_performer_agent.py --mode drift
python3 scripts/confabulator_performer_agent.py --mode duet
python3 scripts/confabulator_performer_agent.py --mode noise --intensity 0.8
```

The default `xray` mode keeps the raw noise overlay near zero and focuses on
SpectroStream RVQ manipulation. `drift` is smoother, `duet` responds more to
onsets and loudness, and `noise` is the harshest mode.

Record an agent take:

```bash
python3 scripts/confabulator_performer_agent.py --mode xray --record
```

Run a fixed-length take:

```bash
python3 scripts/confabulator_performer_agent.py --mode duet --take 120 --record
```

Useful options:

```text
--intensity 0.0-1.0       How hard the agent pushes the instrument.
--target fractal          Aim for an unusual listening target.
--list-targets            Show the available target descriptions.
--embedding-every 45      Seconds between embedding changes.
--no-start                Do not send play/kick when connecting.
--allow-drums             Allow percussion/drum embeddings.
--seed 123                Repeat the same broad gesture choices.
```

Targets are extra objectives layered on top of the performance mode. They use
the audio features the app actually sends to the agent: energy, brightness,
roughness, onset, and zero-crossing behavior. For example:

```bash
python3 scripts/confabulator_performer_agent.py --mode xray --target fractal
python3 scripts/confabulator_performer_agent.py --mode drift --target organism
python3 scripts/confabulator_performer_agent.py --mode noise --target knife --intensity 0.75
python3 scripts/confabulator_performer_agent.py --mode xray --target void --record
python3 scripts/confabulator_performer_agent.py --mode xray --target seam
python3 scripts/confabulator_performer_agent.py --mode duet --target argument
python3 scripts/confabulator_performer_agent.py --mode drift --target haunt
python3 scripts/confabulator_performer_agent.py --mode xray --target swarm --intensity 0.65
python3 scripts/confabulator_performer_agent.py --mode drift --target palimpsest --record
python3 scripts/confabulator_performer_agent.py --mode xray --target mandala
python3 scripts/confabulator_performer_agent.py --mode drift --target eigen
python3 scripts/confabulator_performer_agent.py --mode duet --target apophenia
python3 scripts/confabulator_performer_agent.py --mode xray --target hilbert --intensity 0.7
python3 scripts/confabulator_performer_agent.py --mode drift --target sigil --record
```

`fractal` tries to create multi-scale spectral complexity without turning into
plain hiss. `filigree` chases bright high-detail texture. `void` looks for
sparse hollow negative space. `knife` seeks sharp transient edges. `organism`
tries to keep slow self-similar mutation alive. `maze` keeps changing direction
before the sound settles. `seam` plays the model's 2-second inference boundary
as a pulse. `argument` keeps the prompt surface, listener, text space, and RVQ
stack in productive disagreement. `haunt` keeps returning to half-remembered
states. `swarm` keeps tiny instabilities moving everywhere at once.
`palimpsest` overwrites the current identity in translucent layers.
`mandala` searches for symmetry across prompt geometry, RVQ/control mirrors,
and rolling audio complexity. `eigen` searches for a self-similar attractor:
the sound returning to itself, but changed. `apophenia` forces coincidences
between unrelated audio features, positions, and parameter ratios. `hilbert`
walks the prompt surface like a recursive space-filling curve. `sigil` hashes
the current prompt labels into modulation patterns, so the instructions become
a control spell rather than only a semantic request.

## Recording Agent Performances

When an agent records or captures audio, the `.confab.json` recipe sidecar
includes an `agent_performance` section. It stores the timecoded commands the
agent sent during the take, so the performance can be inspected or replayed as
a decision trace.

The audio is still written by CONFABULATOR's normal recorder into:

```text
~/Music/CONFABULATOR Captures
```

## Replaying A Trace

An agent trace can be treated like a score or DAW automation lane. It is not
sample-perfect audio recall; it is timed re-performance of the same gestures
into the live model. Because the model is generative, each replay can render
slightly differently while preserving the same command structure.

Summarize a recipe:

```bash
python3 scripts/confabulator_replay_agent_trace.py \
  "$HOME/Music/CONFABULATOR Captures/CONFABULATOR_20260607_015656_retro.confab.json" \
  --summary
```

Dry-run the first few events:

```bash
python3 scripts/confabulator_replay_agent_trace.py path/to/take.confab.json \
  --dry-run --max-events 20
```

Replay into a running CONFABULATOR:

```bash
python3 scripts/confabulator_replay_agent_trace.py path/to/take.confab.json
```

Replay and record a fresh rendering:

```bash
python3 scripts/confabulator_replay_agent_trace.py path/to/take.confab.json --record
```

Useful replay controls:

```text
--speed 2.0             Replay twice as fast.
--start-at 120          Start from original trace time 120s.
--end-at 240            Stop at original trace time 240s.
--include-recorder      Also replay original recordStart/recordStop/capture commands.
--no-start              Do not send play/kick before replay.
```

Older recipes created before the full-trace change may contain only the tail of
the performance. New recipes keep the complete agent event history for the take.

## Design Notes

The socket is intentionally simple. Large language models can make high-level
decisions every second or two, while a small local script can handle fast,
smooth gestures between those decisions. For example:

- The AI decides: "make this brighter and less stable."
- The local script gradually moves `rvqForce`, `brightness`, and listener
  position over 800 ms.
- CONFABULATOR records the resulting sound and the command trace.
