# CONFABULATOR

CONFABULATOR is a standalone macOS instrument built on
[Magenta RealTime 2](https://github.com/magenta/magenta-realtime). It generates
music continuously, then lets you push, bend, damage, and reroute the model while
it is playing.

The starting point is Magenta RT Collider: you place prompts or embeddings on a
2D surface, move the listener around them, and the model blends between those
ideas in real time. CONFABULATOR adds a black, white, and red control rack for
latent-style manipulation, SpectroStream RVQ token damage, audio effects, saved
settings banks, and audio-to-embedding creation.

For the feature guide, see [CONFABULATOR.md](CONFABULATOR.md).

## What You Need

- A Mac with Apple Silicon, meaning an M1, M2, M3, M4, or newer chip.
- macOS with Xcode Command Line Tools installed.
- Internet access for the first model download.
- Enough disk space for the model files. `mrt2_small` is the best first choice.
  `mrt2_base` is larger and needs a stronger Mac to run in real time.

Real-time streaming is designed for Apple Silicon. The original Magenta RT
Python tools can run in other ways, but this app is a native macOS app.

## Fastest Install

If someone gives you `CONFABULATOR.dmg`:

1. Double-click `CONFABULATOR.dmg`.
2. Drag `CONFABULATOR.app` onto `Applications`.
3. Open `CONFABULATOR` from your `Applications` folder.
4. On first launch, let it download the required Magenta RT resources and a
   model.

If macOS says the app is from an unidentified developer, right-click the app,
choose `Open`, then choose `Open` again.

## If You Have An Installer Package

If someone gives you `CONFABULATOR.pkg`:

1. Double-click `CONFABULATOR.pkg`.
2. Follow the installer.
3. Open `CONFABULATOR` from your `Applications` folder.
4. On first launch, let it download the required Magenta RT resources and a
   model.

If macOS says the installer cannot be opened or is from an unidentified
developer, the installer was not Apple-notarized. Control-click it, choose
`Open`, then choose `Open` again.

## If You Have A Release Zip

If someone gives you `CONFABULATOR.zip`:

1. Unzip it.
2. Move `CONFABULATOR.app` into your `Applications` folder.
3. Open it.
4. On first launch, let it download the required Magenta RT resources and a
   model.

If macOS says the app is from an unidentified developer, right-click the app,
choose `Open`, then choose `Open` again.

## Build From Source

Use this when you are installing from GitHub.

### 1. Install Command Line Tools

```bash
xcode-select --install
```

If you already have them, macOS will tell you.

### 2. Install Node

If you use Homebrew:

```bash
brew install node
```

If you do not use Homebrew, install Node from [nodejs.org](https://nodejs.org/).

### 3. Install uv

`uv` is used here to make a small Python environment for CMake.

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Open a new terminal after installing it if the `uv` command is not found.

### 4. Clone The Repo

```bash
git clone --recurse-submodules https://github.com/matdryhurst/magenta-rt-noise-app.git
cd magenta-rt-noise-app
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### 5. Build The App

```bash
uv venv --python 3.12 .venv-build
source .venv-build/bin/activate
uv pip install "cmake<3.28"
cmake . -B build
cmake --build build --target deploy_mrt2_collider -j10
```

When the build finishes, the app is placed here:

```text
~/Applications/CONFABULATOR.app
```

Open it:

```bash
open "$HOME/Applications/CONFABULATOR.app"
```

## First Launch

1. Open `CONFABULATOR.app`.
2. If the app asks to download shared resources, say yes.
3. Download or select a model. Start with `mrt2_small`.
4. Press play.
5. Drag the listener around the prompt surface to hear the model move between
   ideas.

The app stores model files under:

```text
~/Documents/Magenta/magenta-rt-v2
```

If you already have Magenta RT model files somewhere else, use the model picker
to select that folder.

## Quick Start: Make Sound

1. Press play in the transport controls.
2. Move the listener dot around the prompt balls.
3. Type new words into a prompt ball, or add an embedding from the `EMBEDDINGS`
   panel.
4. Use `RANDOM CORE` for a broad reroll.
5. Use `DAMAGE` and `SPECTROSTREAM RVQ` carefully at first. They can get harsh
   quickly.

## Create An Audio Embedding

The `SOURCE` panel has one button:

```text
CREATE EMBED
```

Press it, choose an audio file, and wait. The app listens to that file through
MusicCoCa, turns it into a 768-number style embedding, and places it into the
`VARIOUS` embedding folder. It also creates a prompt ball for it.

This does not copy your audio into the app. It stores the embedding, which is a
compact style vector the model can use as a musical direction.

## Where Things Are Saved

- `SETTINGS BANK` saves the current instrument state in local app storage.
- Audio embeddings you create with `CREATE EMBED` are saved locally in the
  `VARIOUS` bank.
- Model files live in `~/Documents/Magenta/magenta-rt-v2`.

## Troubleshooting

### The App Opens But Makes No Sound

- Make sure a model is loaded.
- Press play.
- Turn the app volume up.
- Check your Mac audio output device.
- Try `CLEAN`, then press play again.

### The Model Download Is Slow

The model files are large. `mrt2_small` is the practical first download.

### Build Fails At CMake

Make sure you ran:

```bash
git submodule update --init --recursive
source .venv-build/bin/activate
uv pip install "cmake<3.28"
```

Then run the build again.

### Build Fails At Node Or npm

Install Node:

```bash
brew install node
```

Then rebuild.

### macOS Blocks The App

Right-click `CONFABULATOR.app`, choose `Open`, then choose `Open` again.

## For Developers

The app lives in:

```text
examples/collider
```

The interface lives in:

```text
examples/collider/ui
```

Useful commands:

```bash
# Rebuild and redeploy the full app
cmake --build build --target deploy_mrt2_collider -j10

# Build a drag-and-drop disk image at build/installer/CONFABULATOR.dmg
scripts/package_confabulator_dmg.sh --skip-build

# Build a double-click installer at build/installer/CONFABULATOR.pkg
scripts/package_confabulator_pkg.sh --skip-build

# Run only the React UI build
cd examples/collider/ui
npm run build
```

To create the clean public-download installer without macOS warnings, sign and
notarize it with Apple Developer ID certificates:

```bash
export MAGENTART_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
scripts/package_confabulator_dmg.sh --notarize

# Optional .pkg installer instead of a .dmg
export CONFABULATOR_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
scripts/package_confabulator_pkg.sh --notarize
```

The original Magenta RT docs are still useful for the model, Python API, export
tools, and lower-level engine work:

- [Model card](MODEL.md)
- [Original documentation folder](docs/)
- [Magenta RealTime 2 upstream repo](https://github.com/magenta/magenta-realtime)

## Credits And License

CONFABULATOR is a fork of Magenta RealTime 2 by Google DeepMind. The codebase is
Apache 2.0. The model weights are CC-BY 4.0. See [MODEL.md](MODEL.md) and
[LICENSE](LICENSE).
