# The speech model

Sorello transcribes with kea-b-0.1, a 1-bit derivative of NVIDIA Parakeet TDT 0.6B v2: a Core ML encoder holding
one 15-second function, the front end's constants, the decoder and joint weights, and the vocabulary. The weights are
not in Git. Their licence and attribution are in `Resources/ModelNotices`.

## The pin

`model.lock.json` names the one bundle a build may ship. `manifest_sha256` is the SHA-256 of the bundle's
`bundle.json`, and `bundle.json` lists every file of the bundle with its own SHA-256, so the pin fixes every byte.
`export_sha256` records which training export the bundle was converted from.

The pin is checked twice. `scripts/build-app.sh` refuses a bundle whose `bundle.json` does not match the pin, and
copies into the app only the files the manifest lists, each after checking its hash. At launch the speech engine
checks every file against the manifest again before it loads anything, so a damaged install fails as
"model corrupt" rather than transcribing with the wrong weights.

## Pointing a build at the bundle

Keep the bundle outside the checkout and set `SORELLO_MODEL_DIR` to its directory (the one holding `bundle.json`):

```sh
SORELLO_MODEL_DIR=/path/to/bundle make app                     # build/Sorello Dev.app with the model
SORELLO_MODEL_DIR=/path/to/bundle swift test --filter SpeechEngineTests   # the tests that need the model
swift run sorello-transcribe --model /path/to/bundle --store /tmp/model-store speech.wav
```

`make check` needs no model. The first load at a new store path compiles the model for the Neural Engine and can take
a few minutes; later loads from the same path are quick. On a Mac without a Neural Engine, and with `--cpu`, nothing is
compiled, so there is no such wait. Changing the model, or the pin, is the owner's decision.
