# Sorello

Local dictation for macOS, by Audeo Labs. Hold a key, speak, release: the words appear at the cursor. Tap the
key twice to dictate hands-free, and once more to finish. Speech recognition runs on your Mac with a bundled
model. Sorello makes no network connections.

Sorello needs a Mac running macOS 15 or later. On a Mac with a Neural Engine, which is every Apple silicon Mac,
recognition runs there. On an Intel Mac it runs on the processor, more slowly. It is in early development:
version 0.0.1.

## Build

Install Xcode 27. Model weights are kept outside Git; point `SORELLO_MODEL_DIR` at the bundle that
`Models/model.lock.json` pins.

```sh
make check
make app SORELLO_MODEL_DIR=/path/to/model/bundle
open "build/Sorello Dev.app"
```

Without `SORELLO_MODEL_DIR` the app still builds, but it cannot transcribe. A development build runs on the Mac that
built it; `CHANNEL=release` builds a universal app for Apple silicon and Intel, and `ARCHS="arm64 x86_64"` makes any
build universal.

## Check a build

The packaged app proves itself without any permission. The self-test runs each recording through the app's own
session, with the file in place of the microphone and nothing pasted, and prints what would have been inserted:

```sh
say -o hello.wav --data-format=LEI16@16000 "Hello from the self test"
"build/Sorello Dev.app/Contents/MacOS/Sorello" --self-test hello.wav
"build/Sorello Dev.app/Contents/MacOS/Sorello" --snapshots build/app-snapshots
```

The second command draws every window and every setup step as the app wires them, and lists the menu's rows.
`--no-setup` opens the app without its setup window.

Sorello asks for the microphone, to hear you, and for Accessibility, to see its shortcut and to paste. An
ad hoc development build may need both granted again after it is rebuilt.

[ARCHITECTURE.md](ARCHITECTURE.md) describes how the app is put together, and [AGENTS.md](AGENTS.md) how to
work on it. [ThirdPartyNotices.md](ThirdPartyNotices.md) lists the work by others that Sorello includes.
