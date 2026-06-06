# CONFABULATOR

CONFABULATOR is the Collider-based standalone app in this fork. It keeps
Collider's prompt surface, where prompt balls are blended by moving a listener
around a 2D field, and adds a performance rack for model controls, audio
embeddings, SpectroStream RVQ manipulation, and output damage.

For normal installation and use, start with the top-level
[README](../../README.md). For the plain-English feature guide, see
[CONFABULATOR.md](../../CONFABULATOR.md).

## Build And Deploy

```bash
uv venv --python 3.12 .venv-build
source .venv-build/bin/activate
uv pip install "cmake<3.28"
cmake . -B build
cmake --build build --target deploy_mrt2_collider -j10
```

After a successful build, the app is deployed to:

```text
~/Applications/CONFABULATOR.app
```

Open it:

```bash
open "$HOME/Applications/CONFABULATOR.app"
```

## Use CONFABULATOR

1. Launch `CONFABULATOR.app`.
2. Download or select a model. Start with `mrt2_small`.
3. Press play.
4. Drag the listener around the prompt surface to blend prompt balls.
5. Use `CREATE EMBED` to turn an audio file into a playable embedding in the
   `VARIOUS` folder.
6. Use the manipulation rack to bend, damage, or randomize the stream.

## Agent Performance

CONFABULATOR can expose a localhost JSON-lines socket for AI performers at
`127.0.0.1:47873`. Agents receive compact audio features and structured
instrument state, then send commands back to move prompts, choose embeddings,
turn RVQ/damage controls, trigger macros, and control the recorder.

See [Agent Performance Socket](../agent_performance.md).
