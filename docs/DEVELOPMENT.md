# Developing Sorello

This is for people who build Sorello. [README.md](../README.md) is for people who use it.
[ARCHITECTURE.md](../ARCHITECTURE.md) is the contract the code is written against: read it before changing
anything. [AGENTS.md](../AGENTS.md) says how changes are made.

## What you need

A Mac with macOS 26 or later and Xcode 27 (Swift 6.4). Sorello is one Swift package; there is no Xcode project.

## Build and test

```sh
make check        # the rule checks, the build and every test; needs no model, and no network once Sparkle is fetched
make app          # build/Sorello Dev.app
make run          # make app, then open it
make snapshots    # every pill state and screen as PNG files in build/snapshots
```

Every commit passes `make check`. On a Mac with few cores, `make check TEST_FLAGS=--no-parallel` runs the tests one
at a time, as GitHub's runner does.

`make app` runs `scripts/build-app.sh`, which reads these variables:

- `CHANNEL`: `dev` (the default), `nightly` or `release`. See "Channels" below.
- `ARCHS`: `arm64`, `x86_64` or both. A development build is for the Mac that builds it; a nightly or release
  build is universal. `ARCHS="arm64 x86_64"` makes any build universal.
- `BUILD_NUMBER`: the build number, one to three whole numbers separated by dots. The default is `BUILD` in
  `Config/identity.conf`.
- `SORELLO_MODEL_DIR`: a local copy of the speech model, for an app that carries the model and never downloads
  it: `make app SORELLO_MODEL_DIR=/path/to/model/bundle`.
- `CODESIGN_IDENTITY`: the signing identity. The default, `-`, signs ad hoc.

An ad hoc development build may need the microphone and Accessibility granted again after it is rebuilt.

## The speech model

Model weights are kept outside Git. `Models/model.lock.json` pins the model and says where the app downloads it
from; the app fetches it once, when the user presses Download in setup or on the General screen.
[Models/README.md](../Models/README.md) describes the pin, how it is checked, and how to keep a local copy for the
tests that need the model.

## Check a build

The packaged app proves itself without any permission. The self-test runs each recording through the app's own
session, with the file in place of the microphone and nothing pasted, and prints what would have been inserted:

```sh
say -o hello.wav --data-format=LEI16@16000 "Hello from the self test"
"build/Sorello Dev.app/Contents/MacOS/Sorello" --self-test hello.wav
"build/Sorello Dev.app/Contents/MacOS/Sorello" --snapshots build/app-snapshots
```

The self-test needs the model: one the app carries (`SORELLO_MODEL_DIR`), one given with `--model <bundle-dir>`, or
one that app has already downloaded into its store. A fresh build without the model passes only the `--download`
form below. The second command draws every window and every setup step as the app wires them, and lists the menu's
rows.
`--self-test --cpu` runs the speech model on the processor, as on a Mac without a Neural Engine. `--no-setup` opens
the app without its setup window.

The model's download is proved the same way, without touching the app's own copy of the model. The first command
makes the packaged app download its model with its own pin into a temporary store, then dictate; the second fetches
this Mac's build into a store you choose, as the app would, and transcribes with it. Both say what they fetched.

```sh
"build/Sorello Dev.app/Contents/MacOS/Sorello" --self-test --download hello.wav
swift run sorello-transcribe --download --pin Models/model.lock.json --store /tmp/model-store hello.wav
```

Run the second again and nothing is fetched; stop it in the middle and run it again and it goes on from where it
stopped. Its `--source` fetches from another address instead, such as a server on this Mac at `http://127.0.0.1`,
to stage a failure.

A build with an update feed proves its updater the same way. Run this on a copy of the app, against a feed on the same
Mac: it checks that feed, for that run only, and when the feed lists a newer build signed with the update key it
installs it over the copy as the command ends, without opening it.

```sh
"/path/to/copy/Sorello Nightly.app/Contents/MacOS/Sorello" --self-test --update http://127.0.0.1:8000/appcast.xml
```

`swift run SorelloSnapshots --demo` shows the real pill on the real screen for 20 seconds, cycling through its
states, to check it against the hardware by eye.

## Channels

`Config/identity.conf` gives the app's version and its three identities. Each has its own settings, model and
permissions, so all three can be installed on one Mac. Two that are running both answer the shortcuts.

| Channel | App | Bundle identifier |
|---|---|---|
| `dev` | Sorello Dev | `com.audeolabs.sorello.dev` |
| `nightly` | Sorello Nightly | `com.audeolabs.sorello.nightly` |
| `release` | Sorello | `com.audeolabs.sorello` |

## Updates

Sorello updates itself with Sparkle. A nightly follows the nightly feed and a release follows the release feed, so
neither is offered the other's builds. A development build has no feed and never checks. `Config/identity.conf`
gives the two feeds, `NIGHTLY_FEED` and `RELEASE_FEED`, and `UPDATE_PUBLIC_KEY`, the public half of the key updates
are signed with; `scripts/build-app.sh` writes them into the app's `Info.plist`. Each feed is a file named
`appcast.xml`, published beside the DMG it lists. ARCHITECTURE.md, section 6, "Updates", says how the app uses it.

## Signed builds

The app is handed out as a DMG, signed with Audeo Labs' Developer ID and notarized by Apple.
`scripts/notarize-app.sh <app> <dmg>` has Apple notarize the app and staples the ticket to it, then makes the DMG,
signs it and has it notarized too. It needs a Developer ID signature on the app and an App Store Connect API key in
the environment. Notarizing uploads the app to Apple. `scripts/write-appcast.sh <app> <dmg> <url> <appcast>` writes
the update feed that lists that DMG, signed with the update key. It refuses a key that is not the private half of
`UPDATE_PUBLIC_KEY`, so a feed is never written that installed apps would refuse.

GitHub Actions runs four workflows, in `.github/workflows`:

- **Check** runs `make check` on every pull request and every push to `main`.
- **Package** is what Nightly and Release share. It builds a commit of `main` whose check passed, signs and
  notarizes it, and proves the app from the DMG with `--snapshots` and `--self-test --download`.
- **Nightly** runs every night, and when it is started by hand. If `main` has not moved since the last nightly it
  does nothing. Otherwise it builds "Sorello Nightly" and publishes it in the `nightly` prerelease, in place of the
  night before's: `Sorello-Nightly.dmg`, the same image under a name of its own build, and `appcast.xml`. The feed
  gives the image's own address, and the images of the last thirty builds stay, so an update that was offered
  earlier still installs after later nightlies. Its build number, shown in About, is the number of commits
  in the history of the commit it was built from, so it rises with every commit to `main`.
- **Release** is started by hand, from `main`. It builds "Sorello" and leaves `Sorello.dmg` and `appcast.xml` in a
  draft release named for the version, such as `v0.0.1`. It refuses a version that already has a release, a draft
  or a tag.

To cut a release: raise `VERSION` in `Config/identity.conf` and merge that to `main`; once Check has passed on that
push, start Release from the Actions tab; then look over the draft and publish it, which creates the tag.
Publishing is the owner's decision.

The workflows read six repository secrets. Their values are never in the repository or in a log.

- `DEVELOPER_ID_P12`: the Developer ID certificate and its private key, a .p12 file in base64.
- `DEVELOPER_ID_P12_PASSWORD`: the password of that .p12 file.
- `NOTARY_KEY_P8`: the App Store Connect API key used to notarize, a .p8 file in base64.
- `NOTARY_KEY_ID`: that key's identifier.
- `NOTARY_ISSUER_ID`: the identifier of the key's issuer.
- `UPDATE_SIGNING_KEY`: the private half of the key updates are signed with, its 32-byte seed in base64.

## The iPhone app

Sorello for iPhone, with its keyboard and its Live Activity, is in `iOS/` and has its own build:
[iOS/README.md](../iOS/README.md). `make check` and GitHub Actions do not build or test it. `make -C iOS check`
does, on a Mac.

## More

- [ARCHITECTURE.md](../ARCHITECTURE.md): how the app is put together, and why.
- [docs/dictionary/DESIGN.md](dictionary/DESIGN.md): the dictionary and correction suggestions.
- [Models/README.md](../Models/README.md): the speech model and its pin.
- [ThirdPartyNotices.md](../ThirdPartyNotices.md): the work by others that Sorello includes.
