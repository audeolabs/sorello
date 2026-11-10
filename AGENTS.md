# Working on Sorello

Sorello is a local dictation app for macOS. Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing anything: it
is the contract the code is written against, and it says where each kind of code belongs.

## Commands

```sh
make check        # rule checks, build, tests. Every commit passes this. Needs no model and no network.
make snapshots    # every pill state and screen as PNG files in build/snapshots
make app          # build/Sorello Dev.app; add SORELLO_MODEL_DIR=<pinned bundle> to include the model
```

The package builds only on macOS 26 or later with Xcode 27 (Swift 6.4). There is no Xcode project.

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
- **Dependencies.** Sorello has none. Add one only when it clearly earns its place, and say why in the pull
  request.

## Privacy rules

These hold for code, tests, fixtures, logs, commit messages and pull requests.

- Never commit, print, upload or place in a fixture: signing credentials, API keys, `.env` contents, real audio
  or transcripts, selected text or clipboard contents, window titles or other app context, screenshots of
  someone's screen, or identifying filesystem paths. Do not read `.env` files.
- Test audio is synthetic (`say`) and test text is invented.
- No telemetry, crash reporting, persistent logging or network access without the owner's explicit approval.
  Diagnostics go through `Diagnostics`, whose events cannot carry content.
- Do not trigger permission prompts or change system permissions on someone's Mac without their approval.
- Model weights stay out of Git. `Models/model.lock.json` pins the bundle.

## Provenance

Sorello's code is written from ARCHITECTURE.md. Do not copy code into it from other dictation apps, including
the macOS app it replaces. The exceptions are recorded in ARCHITECTURE.md, section 12, and their notices are in
ThirdPartyNotices.md.

## What needs the owner

Pushing to `main`, merging, tagging, publishing a release, adding a dependency, changing the model, and
anything that sends data off the Mac.
