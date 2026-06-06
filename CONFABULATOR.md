# CONFABULATOR Feature Guide

CONFABULATOR is a live music generator and noise instrument. It starts with
Magenta RealTime 2 making continuous audio. You then steer that stream with
prompt balls, audio embeddings, model controls, RVQ token manipulation, and
effects.

The simplest way to understand it:

1. The prompt surface chooses what kind of music the model is trying to make.
2. The manipulation rack changes how the model thinks, moves, breaks, and
   outputs sound.
3. The settings bank lets you save a playable state and come back to it.

## The Prompt Surface

The big open area is the prompt surface.

- Prompt balls are musical ideas.
- The listener dot is what the model is listening to right now.
- Drag the listener toward a ball to hear more of that idea.
- Put the listener between several balls to blend them.
- Move the balls to reshape the field.
- Edit a text ball to type a new prompt.

This is the heart of the instrument. If the model feels stuck, move the
listener, change the prompt balls, or press `RANDOM CORE`.

## Transport And Model Controls

The transport controls start and stop sound.

- `Play/Pause`: starts or stops the stream.
- `Volume`: app output volume.
- `Reset`: restarts the model from its current setup.
- `Model selector`: choose or download a Magenta RT model.

Use `mrt2_small` first. It starts faster and is easier to run in real time.
Use `mrt2_base` if your Mac is strong enough and you want the bigger model.

## MANIPULATE Rack

The rack at the bottom is where most of CONFABULATOR lives.

### CLEAN

`CLEAN` returns the instrument to a more stable state. Use it when everything is
too mangled, too loud, or too lost.

### RANDOM CORE

`RANDOM CORE` changes the musical source state without maxing out the damage
section. It rerolls embeddings, sampling settings, PCA shape, RVQ controls, and
performance drift. It is meant to create a new playable situation, not just
blast noise over the top.

## MODEL

These controls affect the model before the audio effects stage.

- `NO DRUMS`: asks the model to avoid drums.
- `CHAOS`: higher values make the model take wilder guesses. Lower values are
  steadier.
- `TOKEN K`: controls how many possible next tokens the model can choose from.
  Low values are tighter. High values are stranger.
- `PROMPT CFG`: how strongly the prompt or embedding pulls the model. Higher
  values make the model obey the prompt harder.
- `UNMASK`: how much of each generation step can update. Higher values can feel
  more unstable and reactive.
- `SEED ROT`: changes the model's random seed path. Good for escaping a loop.

## DAMAGE

`DAMAGE` is an audio processor after the model. It treats Magenta RT as a live
sound source and bends the output.

- `RANDOM`: randomizes only the damage section.
- `ZERO`: turns the damage section back down.
- `WET`: dry/damaged blend. At 0 you hear mostly the model. At 1 you hear mostly
  the damaged signal.
- `DRIVE`: saturation and overload.
- `FOLD`: wavefolding, which bends peaks back into themselves.
- `CRUSH`: bit and sample-rate style degradation.
- `RING`: metallic ring modulation.
- `COMB`: short feedback delays that can sound resonant, hollow, or flanged.
- `BODY`: resonant body color, like pushing the sound through an artificial
  chamber.
- `SMEAR`: diffusion and blur.
- `STUTTER`: grabs small pieces and repeats them.
- `PITCH`: scrapes pitch around the center point.
- `HARM`: emphasizes and bends harmonic content.
- `NOISE`: adds a small amount of extra noise. Keep this low if you want to hear
  the model clearly.

If you only hear white noise, turn down `WET`, `NOISE`, `CRUSH`, and `RING`, or
press `ZERO`.

## SPECTROSTREAM RVQ

This is the most model-specific part of the instrument.

Magenta RT does not directly generate a waveform. It generates audio codec
tokens. SpectroStream turns those tokens into sound. The RVQ controls disturb
that token stream before it becomes audio.

Plainly: this section damages the model's internal musical material, not just
the final speaker output.

- `CLEAR`: turns the RVQ manipulation off.
- `FORCE`: overall amount of RVQ token interference.
- `BREATHE`: makes the interference move over time.
- `MEMORY`: lets token damage pull from recent token history.
- `COARSE`: targets broad, structural parts of the token stack. This can move
  pitch, register, and large spectral shape.
- `FINE`: targets finer token layers. This tends to sandblast texture while
  leaving the larger gesture more recognizable.
- `SWEEP`: moves through token positions.
- `HOLD`: holds or freezes token choices in short patterns.
- `INVERT`: flips token choices into stranger parts of the codebook.
- `JITTER`: shakes token choices.
- `STRIDE`: skips through token positions in stepped patterns.

Use small amounts first. The RVQ section can be more interesting before it is
fully destroyed.

## EMBEDDINGS

Embeddings are prompt-like musical anchors. Instead of a sentence, they are
768-number MusicCoCa vectors.

The built-in folders are named for broad sound behavior rather than genre:

- `MUTATE`
- `WIRE`
- `PLUCK`
- `BOW`
- `BRASS`
- `STRIKE`
- `VOX`
- `DRONE`
- `VOLT`
- `DECONSTRUCT`
- `FORMANT`

Controls:

- Folder dropdown: choose an embedding bank.
- Item dropdown: choose a specific embedding in that bank.
- `ADD EMBED`: add the selected embedding as a ball.
- `SET SELECTED`: replace the selected ball with the chosen embedding.
- `REROLL EMBED`: replace the selected ball with a random embedding.

### SOURCE: CREATE EMBED

`CREATE EMBED` lets you choose an audio file from your computer.

The app listens to that file with MusicCoCa and creates an embedding from it.
When it finishes:

- the embedding is added to a folder called `VARIOUS`;
- the dropdown switches to that new embedding;
- a new prompt ball appears on the surface;
- that ball can be moved, saved, rerolled, and blended like the built-in
  embeddings.

This usually takes a few seconds. Longer files are reduced into one style
direction, not copied into the app as audio.

## PCA STYLE

PCA is a way of moving through broad directions in the embedding space.

- `ADD PCA`: adds a special `pca` ball to the prompt surface.
- `AXIS 1-6`: move the `pca` ball through six learned style directions.

Use this when you want the model to lean into a vague shape rather than a named
prompt. It is less like choosing "guitar" and more like turning a hidden style
magnet.

## TEXT ENCODER

Normally, text prompts are encoded live by MusicCoCa. The Text Encoder section
lets you capture a text prompt as a fixed embedding and then bend that vector.

How to use it:

1. Select a text prompt ball.
2. Press `CAPTURE`.
3. Wait for the status to become `VEC`.
4. Move the dials.

Controls:

- `CAPTURE`: turns the selected text prompt into a captured vector.
- `RAW`: releases the prompt back to normal text behavior.
- `ZERO`: resets the text-vector dials.
- `CARVE`: pushes the vector into a more exaggerated shape.
- `SCRAMBLE`: adds structured disorder to the vector.
- `MORPH`: pulls the captured vector toward the selected embedding.
- `OPPOSE`: pushes away from the selected embedding.
- `SCAN`: moves through the vector over time.
- `GRAVITY`: pulls the vector back toward its original captured form.

If nothing seems to happen, make sure you selected a normal text prompt, not an
embedding ball, before pressing `CAPTURE`.

## PERFORM

This section is for live movement.

- `JUMP`: jolts seed, sampling, CFG, RVQ controls, and PCA. Use it to knock the
  stream out of a rut.
- `DRIFT`: slowly moves embedding vectors away from themselves.
- `SNAP`: pulls drifting embeddings back toward their original identity.

### Macros

These buttons move several parts of the instrument at once.

- `METAL`: sharper, more resonant, more physical.
- `MELT`: blurred, smeared, and unstable.
- `SHRED`: high-energy token and model disruption.
- `GHOST`: lighter, quieter, more spectral.

They are performance states. Press one, then keep playing the surface and dials.

## SETTINGS BANK

The settings bank saves a snapshot of the instrument.

It saves:

- prompt balls and listener position;
- selected embeddings;
- source-created embeddings used by the patch;
- model controls;
- Damage settings;
- SpectroStream RVQ settings;
- Text Encoder settings;
- performance drift/snap settings.

Controls:

- `SAVE`: save the current state.
- `LOAD`: restore the selected state.
- `DELETE`: remove the selected saved state.

Settings banks are local to the app on your Mac.

## Good Starting Moves

### Stable Music First

1. Press `CLEAN`.
2. Keep `DAMAGE` low.
3. Keep `SPECTROSTREAM RVQ` low or clear.
4. Move the listener between prompt balls.
5. Raise `CHAOS` only a little.

### More Noise, Still Musical

1. Add or create an embedding.
2. Raise `PROMPT CFG`.
3. Add `DRIFT`.
4. Use a small amount of `RVQ FORCE`.
5. Bring in `WET`, `DRIVE`, `COMB`, or `SMEAR`.

### Broken Machine

1. Press `SHRED`.
2. Raise `RVQ COARSE`, `RVQ FINE`, or `RVQ JITTER`.
3. Push `WET`, `FOLD`, `RING`, and `STUTTER`.
4. Use `JUMP` when the loop becomes too stable.

## What Is Actually Being Manipulated?

CONFABULATOR works on several layers at once:

- Text and audio prompts become MusicCoCa embeddings.
- Embedding balls steer the model before sound is made.
- PCA and Text Encoder controls bend those embeddings.
- SpectroStream RVQ controls perturb the codec tokens the model generates.
- Damage controls process the final audio stream.

So some controls change the model's direction, some damage its token stream, and
some process the sound after it exists. The best results usually come from using
all three gently, then pushing one of them too far on purpose.
