# Sorello

Local dictation for macOS, by Audeo Labs. Hold a key, speak, release: the words appear at the cursor. Tap the
key twice to dictate hands-free, and once more to finish. Speech recognition runs on your Mac. Sorello downloads
its speech model once, during setup, and makes no other network connection.

Sorello needs a Mac running macOS 26 or later. On a Mac with a Neural Engine, which is every Apple silicon Mac,
recognition runs there. On an Intel Mac it runs on the processor, more slowly. It is in early development:
version 0.0.1.

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) says how to build Sorello, check a build and cut a release.
[ARCHITECTURE.md](ARCHITECTURE.md) describes how the app is put together, and [AGENTS.md](AGENTS.md) how to work on
it. [ThirdPartyNotices.md](ThirdPartyNotices.md) lists the work by others that Sorello includes.
