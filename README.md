# Sorello

Sorello is dictation for the Mac that runs on the Mac. Hold a key, speak, and let go: your words are pasted where
the cursor is, in any app. Speech is recognised on your Mac, and nothing you say is sent anywhere. It is made by
Audeo Labs and is in early development, at version 0.0.1. It understands English only.

## Download

- Sorello Nightly, built each night that the code has changed:
  https://github.com/audeolabs/sorello/releases/download/nightly/Sorello-Nightly.dmg
- Sorello, from the latest release, once there is one:
  https://github.com/audeolabs/sorello/releases/latest/download/Sorello.dmg

Until the first release is published, the nightly is the build to get.

Both are signed with Audeo Labs' Developer ID and notarized by Apple.

## Requirements

- macOS 26 or later.
- A Mac with Apple silicon. Sorello is also built for Intel Macs, where speech is recognised on the processor, more
  slowly, but nobody has run it on an Intel Mac yet.
- A 138 MB download for the speech model.
- The microphone and Accessibility permissions.

## More

- [docs/USING.md](docs/USING.md): how to set up and use Sorello, and what to do when something is wrong.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): how to build Sorello and check a build.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the app is put together.
- [ThirdPartyNotices.md](ThirdPartyNotices.md): the work by others that Sorello includes.

## Licence

Sorello's code is under the MIT licence: see [LICENSE](LICENSE). The speech model, kea-b-0.1, is derived from NVIDIA
Parakeet v2 and licensed under CC BY 4.0; its notices ship inside the app and are listed in
[ThirdPartyNotices.md](ThirdPartyNotices.md).
