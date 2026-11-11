# Working on Sorello

Sorello is a local dictation app for macOS. Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing anything: it
is the contract the code is written against, and it says where each kind of code belongs.

## Commands

```sh
make check        # rule checks, build, tests. Every commit passes this. Needs no model.
make snapshots    # every pill state and screen as PNG files in build/snapshots
make app          # build/Sorello Dev.app, which downloads its model; SORELLO_MODEL_DIR=<copy> puts it inside
make -C iOS check # the iPhone app's own checks. CI does not run them (see "The iPhone app" below)
```

The package builds only on macOS 26 or later with Xcode 27 (Swift 6.4). There is no Xcode project.

GitHub Actions runs `make check` on every pull request and on every push to `main`. It also builds the nightly
and release apps, signed and notarized (ARCHITECTURE.md, section 10). All of that is the Mac app's. Their credentials are repository secrets:
they are never in the repository or in a log.

## How changes are made

- **Contract first.** Decide the behaviour and the interface, write it in ARCHITECTURE.md if it is new, write
  tests against it, then write the code. Tests assert what a caller can observe. Do not weaken a test to fit an
  implementation; change an expectation only when the contract changes, and say so.
- **Keep the boundaries.** Pure modules import only Foundation. `SorelloUI` draws values and reports actions; it
  never reaches into the session, the engine or storage. Adapters depend on `DictationCore`, not on each other.
  There are no shared singletons. `scripts/check-rules.sh` enforces what the compiler cannot.
- **One state machine.** All dictation state changes in `reduce`. Do not add flags, generation counters or
  staleness checks beside it; add an event.
- **Look at it.** A change to anything visible is checked in the snapshot images, and anything the tests cannot
  show (shortcuts, the paste, the microphone, the pill on real hardware) is checked by running the app.
- **Small commits.** Each commit builds, passes `make check` and says why it exists, so `git bisect` works.
  Commit messages carry no AI attribution lines.
- **No plans in the repository.** Design notes, roadmaps and review rounds live outside it. Markdown here is for
  users (README) or maintainers (this file, ARCHITECTURE.md, the dictionary design).
- **Dependencies.** Sorello has one, Sparkle, which updates the app. SwiftPM fetches it on the first build. Add
  another only when it clearly earns its place, and say why in the pull request.

## The iPhone app

`iOS/` holds Sorello for iPhone, with its own contract ([iOS/ARCHITECTURE.md](iOS/ARCHITECTURE.md)) and its own
build ([iOS/README.md](iOS/README.md)). ARCHITECTURE.md, section 13, says how it fits with the Mac app.

- It links the package's `SpeechEngine`, `DictionaryKit` and `TextRules`. A change to one of them is a change to
  both apps: run `make -C iOS check` on a Mac as well as `make check`.
- Neither `make check` nor GitHub Actions builds or tests it. Run `make -C iOS check` before merging a change to
  `iOS/`.
- It keeps the bundle identifiers, App Group, URL scheme, universal link and stored names it was first published
  with, so that an update replaces the app people already have and keeps their settings. Never rename one.

## Privacy rules

These hold for code, tests, fixtures, logs, commit messages and pull requests.

- Never commit, print, upload or place in a fixture: signing credentials, API keys, `.env` contents, real audio
  or transcripts, selected text or clipboard contents, window titles or other app context, screenshots of
  someone's screen, or identifying filesystem paths. Do not read `.env` files.
- Test audio is synthetic (`say`) and test text is invented.
- No telemetry, crash reporting, persistent logging or network access without the owner's explicit approval.
  The owner has approved two connections: the download of the speech model, which the user starts, and the
  check for an update. Neither sends anything about them (ARCHITECTURE.md, section 9). Diagnostics go through `Diagnostics`, whose events
  cannot carry content.
- Do not trigger permission prompts or change system permissions on someone's Mac without their approval.
- Model weights stay out of Git. `Models/model.lock.json` pins the model and says where the app downloads it.

## Provenance

Sorello's code is written from ARCHITECTURE.md. Do not copy code into it from other dictation apps, including
the macOS app it replaces. The exceptions are recorded in ARCHITECTURE.md, section 12, and their notices are in
ThirdPartyNotices.md.

## What needs the owner

Pushing to `main`, merging, tagging, publishing a release, uploading an iPhone build to App Store Connect, adding
a dependency, changing the model, and anything that sends data off the Mac.
