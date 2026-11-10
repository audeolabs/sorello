# The speech model

Sorello transcribes with kea-b-0.1, a 1-bit derivative of NVIDIA Parakeet TDT 0.6B v2: a Core ML encoder holding
one 15-second function, the front end's constants, the decoder and joint weights, and the vocabulary. The weights are
not in Git. Their licence and attribution are in `Resources/ModelNotices`.

## The pin

`model.lock.json` says which model Sorello uses and where the app downloads it from. It ships inside the app.

- `source` is the address the model's files are under: one fixed revision of
  https://huggingface.co/audeolabs/kea-b-0.1-coreml.
- `builds` lists the builds of the model, one per kind of Mac. Each names its `directory` under `source`, the
  `manifest_sha256` of its `bundle.json`, its size in `bytes`, and what it `requires` of the Mac. `bundle.json`
  lists every file of the build with its own SHA-256, so the pin fixes every byte.
- `export_sha256` records which training export the builds were converted from.

The app takes the first build whose requirements the Mac meets (ARCHITECTURE.md, section 5). Today there is one,
for macOS 26 or later. Builds for other Macs are kept on other branches of the model's repository until they have
been tested; listing one here is what ships it.

The pin is checked at every step. A download is refused unless its `bundle.json` has the pinned SHA-256 and every
file matches it. `scripts/build-app.sh`, given a local copy, refuses one the pin does not list, and copies into the
app only the files its manifest lists, each after checking its hash. And each time the speech engine loads the
model it checks every file against the manifest again, so a damaged copy fails as "model corrupt" rather than
transcribing with the wrong weights.

## A local copy

No build needs the model. For the tests that use it, for `sorello-transcribe --model`, or to build an app that
carries the model, keep a copy outside the checkout and set `SORELLO_MODEL_DIR` to its directory (the one holding
`bundle.json`):

```sh
SORELLO_MODEL_DIR=/path/to/bundle make app                     # build/Sorello Dev.app with the model
SORELLO_MODEL_DIR=/path/to/bundle swift test --filter SpeechEngineTests   # the tests that need the model
swift run sorello-transcribe --model /path/to/bundle --store /tmp/model-store speech.wav
```

`make check` needs no model. The first load at a new store path compiles the model for the Neural Engine and can take
a few minutes; later loads from the same path are quick. On a Mac without a Neural Engine, and with `--cpu`, nothing is
compiled, so there is no such wait. Changing the model, or the pin, is the owner's decision.
