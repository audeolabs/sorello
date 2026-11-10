# Sorello for macOS: architecture contract

Sorello is a menu-bar dictation app for Apple Silicon Macs. You hold a key,
speak, and release; the words appear at the cursor. Speech recognition runs
on the Mac with a bundled model. Sorello makes no network connections.

This document is the contract the code is written against. It states what
each part does and where the boundaries are. When behaviour and this
document disagree, one of them is wrong: fix the code, or change the
contract here in the same pull request and say why.

Version 0.0.1 is the first version. It replaces LocalFlow for macOS and
shares no settings, identity or data with it. iOS is next: the modules
marked *neutral* below import nothing from macOS so that an iPhone target
can use them unchanged.

## 1. What the app does

- **Dictate.** A global shortcut starts a dictation. *Hold to Talk* records
  while the shortcut is down. *Tap to Toggle* starts on one press and stops
  on the next. Audio is transcribed while it is recorded, in 15 second
  chunks, so the wait after release covers only the last chunk.
- **Show it.** A black pill at the top of the screen shows the voice as a
  row of dots while recording and a shimmer while the last words are
  transcribed (section 8). On a Mac with a camera island or a notch the
  pill grows out of the housing.
- **Insert.** The text is pasted at the cursor. The previous clipboard is
  restored afterwards unless the user turns that off. *Paste Again* inserts
  the last dictation again.
- **Fit.** Just before pasting, up to 16 characters on each side of the
  cursor are read so that a dictation placed inside a sentence is
  lowercased and loses redundant final punctuation. Nothing read is kept.
- **Rules, not a language model.** Spoken numbers become digits. Voice
  macros replace a complete spoken phrase with saved text. A trailing
  "press enter" presses Return after the paste. Prompt mode (double-tap
  Hold to Talk, off by default) prefixes the text with a tag so an AI agent
  knows it was dictated. All of these are small deterministic rules.
- **Dictionary.** Names and terms bias the recognizer, each with its own
  strength, optionally limited to chosen apps. When the user corrects a
  word right after a dictation, Sorello can offer to add it.
- **Run Log.** The last 20 dictations are kept locally with their audio for
  playback and retry.

Not in 0.0.1: automatic updates (there is no public feed yet), translation,
cloud transcription, LLM cleanup, screen capture. The last four are not
planned.

## 2. Modules

One Swift package. Swift 6 language mode everywhere; no `@unchecked
Sendable` without a comment that says which lock or queue makes it safe.

| Module | Kind | Depends on | Holds |
|---|---|---|---|
| `DictationCore` | neutral, pure | nothing | The session state machine, its runtime, the ports every adapter implements, and `Diagnostics` |
| `TextRules` | neutral, pure | nothing | Numbers, spoken delimiters, macros, prompt tag, insertion-context fitting |
| `DictionaryKit` | neutral | `DictationCore` | Entries, validation, tokenizer, bias graph, casing, correction decisions and the correction watch (which reads text through `TextFieldReading`), the dictionary file |
| `DesignCore` | neutral, pure | nothing | Palette, dot wave, level meter, pill geometry, motion constants, the mark |
| `SpeechEngine` | neutral | `DictationCore`, `DictionaryKit` | Model store, feature front end, Core ML encoder, decoder, chunked streaming |
| `Persistence` | neutral | `DictationCore`, `TextRules` | Settings, macros, Run Log |
| `SorelloUI` | macOS UI | `DesignCore` | The pill, its overlay window, every screen and control |
| `MacPlatform` | macOS | `DictationCore` | Shortcuts, audio capture, text insertion, Accessibility reads, permissions |
| `SorelloApp` | macOS | all of the above | Composition: builds the objects, connects them, owns windows and the menu bar item |
| `Sorello` | executable | `SorelloApp` | `@main` only |
| `SorelloSnapshots` | executable | `SorelloUI` | Renders every pill state and screen to PNG files |
| `sorello-transcribe` | executable | `SpeechEngine` | Transcribes a WAV file with the real model, for verification |

Rules the compiler enforces through the package graph:

- Pure modules import only Foundation (and CoreGraphics types where
  geometry needs them). They never import AppKit, SwiftUI, AVFoundation or
  CoreML.
- `SorelloUI` knows nothing about speech, storage or the session. It draws
  values it is given and reports actions through closures. `SorelloApp`
  maps session state to those values.
- Adapters depend on `DictationCore`, never the reverse, and never on each
  other.
- There is no shared mutable singleton. `SorelloApp` creates each object
  once and passes it to what needs it.

## 3. The session

A *dictation* is one recording and what becomes of it. Each has a
`DictationID`, a number that only grows. All dictation state lives in one
value, `SessionState`, changed only by one pure function:

```swift
static func reduce(_ state: inout SessionState, _ event: SessionEvent,
                   settings: SessionSettings) -> [SessionEffect]
```

`SessionRuntime` (main actor) owns the state. It feeds events to `reduce`,
performs the returned effects through ports, and turns what the ports
report back into events. Nothing else mutates dictation state, and no
callback checks whether it is stale: an event that names a dictation the
state no longer holds is dropped at the top of `reduce`.

### State

```
SessionState
  capture:   idle | awaitingPermission | starting | recording | ending
  pipeline:  [dictation]   audio finished; each is transcribing, ready, or inserting; oldest first
  microphone: unknown | granted | denied
  engine:    preparing | ready | failed
  notice:    Notice?       one short message for the pill, with its expiry
  last:      the last inserted text, for Paste Again
  tap:       double-tap detector state
  holdIsDown, nextID
```

At most one dictation uses the microphone. Any number may be in the
pipeline, so a second dictation can start while the first is still being
transcribed; their text is inserted in the order they were spoken.

### Events

- Triggers: `holdPressed`, `holdReleased(origin)`, `togglePressed`,
  `cancelPressed`, `pasteAgainPressed`, `pillStopClicked`,
  `pillCancelClicked`. Each carries the monotonic time it arrived.
  `origin` is `keyUp` or `interrupted` (the shortcut ended without a
  genuine key release).
- Capture: `started`, `failed(reason)`, `stalled`, `interrupted(reason)`,
  `ended(summary)`, each with its `DictationID`.
- `transcript(id, result)`, `insertion(id, outcome)`, `timer(id)`,
  `microphoneAccess(access)`, `engine(readiness)`.

### Effects

`requestMicrophoneAccess`, `startCapture(id)`, `stopCapture(id)` (finish
and deliver what was heard), `abortCapture(id)` (discard), `openStream(id,
options)`, `finishStream(id, style)`, `cancelStream(id)`, `insert(id,
plan)`, `reinsert(text)`, `setTimer(id, after)`, `cancelTimer(id)`,
`record(entry)` (Run Log), `watchForCorrection(id, text)`.

### Rules

1. **Start.** A hold or toggle press while `capture` is `idle` starts a
   dictation: allocate the id, `startCapture`, `openStream`, and set a 2 s
   start timer. If the microphone is `denied`, show the microphone notice
   and start nothing. If it is `unknown`, request access first; when
   granted, a toggle press proceeds and a hold press proceeds only if the
   key is still down. If the engine has `failed`, show the engine notice
   and start nothing. An engine that is still `preparing` does not block
   recording: the transcript waits behind preparation.
2. **Recording.** `capture.started` moves `starting` to `recording` and
   cancels the start timer. A release that arrived during `starting` is
   applied now.
3. **Stop.** Releasing Hold to Talk, pressing Tap to Toggle again, or
   clicking the pill in toggle mode sends `stopCapture` and moves to
   `ending`. `capture.ended` moves the dictation to the pipeline and sends
   `finishStream`, unless less than 0.15 s of audio was captured, in which
   case the stream is cancelled and nothing is shown.
4. **Too-short holds.** With prompt mode on, a hold released within 0.3 s
   is discarded (`abortCapture`, `cancelStream`) and arms the double tap.
   A Hold to Talk press within 0.4 s of that release starts a dictation in
   prompt style. The tap arms only if it began while the session was idle,
   ended with a genuine `keyUp`, and nothing started in between.
5. **Cancel.** Escape, or the pill's cancel button, while starting or
   recording discards the dictation. While only waiting, it cancels every
   pipeline item that has not begun inserting. Escape is consumed only
   when it cancels something.
6. **Other presses.** A toggle press during a hold recording, and a hold
   press during a toggle recording, are ignored. A start press during
   `ending` is remembered (one at most) and applied when the capture ends.
7. **Order.** A transcript marks its dictation ready. The oldest pipeline
   item is inserted when it is ready; later items wait for it. Empty text
   removes the item and shows the brief "nothing heard" notice.
8. **Insertion.** `inserted` removes the item, remembers the text for
   Paste Again, records the Run Log entry and, if suggestions are on,
   starts a correction watch. `leftOnClipboard` does the same and shows a
   notice telling the user to paste. `failed` records the entry and shows
   an error notice.
9. **Failures.** The start timer firing in `starting` aborts with the
   microphone-unavailable notice. `stalled` (no audio for 2 s) and
   `interrupted` (device removed, sleep, lock) stop the capture and
   transcribe what was captured. A recording is stopped the same way after
   15 minutes. A failed transcript removes its item, records the entry with
   its audio so it can be retried, and shows an error notice.
10. **Paste Again** reinserts `last` when nothing is recording or waiting.
11. **Notices** expire by timer: 1.4 s for information, 4 s for errors, or
    when a new dictation starts.

### What the pill shows

`PillContent` is a pure function of `SessionState`:
`listening` while starting or recording; otherwise an error `notice`;
otherwise `waiting` while the pipeline is not empty (with the reason
`preparingModel` when the engine is not ready); otherwise an information
`notice`; otherwise `hidden`. Audio level does not pass through the state.
The runtime hands each captured chunk, with its time, to a `LevelSink`, and
the pill reads the level from there.

## 4. Ports

Defined in `DictationCore/Ports.swift`. Each is small enough to fake in a
test.

| Port | Implemented by | Purpose |
|---|---|---|
| `AudioCapturing` | `MacPlatform` | Start a capture; deliver 16 kHz mono `Float` chunks as an async stream; stop or abort |
| `SpeechTranscribing`, `SpeechStreaming` | `SpeechEngine` | Prepare the model, report readiness, open a stream, append samples, finish with text, cancel |
| `TranscriptProcessing` | `SorelloApp` over `TextRules` | Raw transcript, style and insertion context in; text to insert out |
| `InsertionContextReading` | `MacPlatform` | Up to 16 characters each side of the cursor; never from secure fields; gives up after 0.3 s |
| `TextInserting` | `MacPlatform` | Insert a plan; report `inserted`, `leftOnClipboard` or `failed` |
| `TextFieldReading` | `MacPlatform` | Read the focused text field through Accessibility, for the two readers above and the correction watch |
| `MicrophoneAuthorizing` | `MacPlatform` | Current access, and a request |
| `FrontmostAppReading` | `MacPlatform` | Bundle identifier and name of the app in front, read when a dictation starts |
| `HistoryRecording` | `Persistence` | Save a Run Log entry and its samples |
| `LevelSink` | `SorelloApp`, over `SorelloUI`'s level feed | Hear each captured chunk with its time, to show the voice |
| `SessionClock` | `DictationCore` | Monotonic now, and sleeping; a manual clock in tests |

## 5. Speech engine

Ported from LocalFlow's runtime, which was measured and tuned there:

- The model is kea-b-0.1, a 1-bit derivative of NVIDIA Parakeet v2, as a
  Core ML encoder with one 15 second function running on the Neural Engine
  (`cpuAndNeuralEngine`), a vDSP feature front end and an Accelerate TDT
  decoder. English only.
- `SpeechEngine` is an actor with its own serial executor. Model loading,
  warm-up and every prediction run there, one at a time. `append` on a
  stream never waits for model work.
- The bundle is copied once to `Application Support/<bundle id>/Models/<hash>`
  under a file lock, because Core ML's Neural Engine cache is keyed by the
  model file's path and identity; loading from the app bundle would
  recompile after every update. Each file's SHA-256 is checked against the
  bundle's manifest before loading.
- Audio is cut into 15 s chunks that overlap by 2 s and are joined on a
  word both chunks heard. Long silences are compacted first. The shared
  vectors in `Tests/Vectors` pin this behaviour, as they do on Linux.
- Preparation starts at launch. The first preparation on a machine can take
  minutes; the menu and the General screen show its state and offer a retry
  after a failure.
- The dictionary biases decoding through a graph built per dictionary
  revision and app. `docs/dictionary/DESIGN.md` is the contract for
  entries, validation, boosting and correction suggestions.

## 6. macOS adapters

### Shortcuts

- A binding is either a key with optional modifiers, or a set of modifier
  keys alone (left and right distinguished; Fn is a modifier here).
  Defaults: Hold to Talk is Fn; Tap to Toggle and Paste Again are unset.
- One active event tap at the session level reads key and modifier events.
  It needs Accessibility. Without it the adapter reports
  `needsAccessibility` and no shortcut works.
- A key binding consumes its own key-down and key-up. A modifier-only
  binding consumes nothing. A modifier-only hold starts at once; if another
  key goes down within 0.3 s the hold was a chord, and the dictation is
  aborted without a notice.
- If the system disables the tap, the adapter enables it again and reports
  `holdReleased(interrupted)` for a hold in progress.
- Escape is delivered as `cancelPressed`; the tap consumes it only when the
  session says it cancelled something.
- The shortcut recorder in Settings reads the next key or modifier set from
  the same tap, and refuses a binding already used by another action.

### Audio capture

- `AVCaptureSession` with an audio data output on a private queue. The
  audio engine's input tap is not used: with some Bluetooth and aggregate
  devices it delivers no buffers.
- The input is the system default, or a microphone chosen in Settings and
  found again by its unique identifier. Samples are converted to 16 kHz
  mono `Float`.
- The session runs only during a dictation, so the system's microphone
  indicator is on only then. Audio stays in memory. Nothing is written to
  disk until the Run Log entry is saved after insertion.
- Start gives up after 2 s. A capture that delivers nothing for 2 s reports
  `stalled`.

### Text insertion

1. Wait, up to 0.6 s, until the shortcut's modifier keys are up.
2. If restoring, snapshot the pasteboard.
3. Write the text. When it will be restored, mark it transient so clipboard
   managers skip it.
4. Post Command-V, using the key that types "v" in the current layout.
5. For "press enter", post Return 80 ms later.
6. After 1 s, restore the snapshot if the pasteboard still holds our text.

Without Accessibility no key can be posted: the text stays on the clipboard
and the outcome is `leftOnClipboard`. Insertion sits behind `TextInserting`
so another strategy (typing, or per-app choices) can be added without
touching the session.

### Accessibility reads and permissions

- `TextFieldReading` wraps the focused element: its selected range, its
  length and a substring. Secure text fields always read as nothing.
- Microphone access is requested the first time a dictation needs it.
  Accessibility is granted in System Settings; setup opens the pane with a
  card to drag in (adapted from Scrawl and AskForPermission, MIT, notices
  in `ThirdPartyNotices.md`).

## 7. Persistence

Everything is under `Application Support/<bundle id>/`. Files are written
atomically and carry a `version`. A file that cannot be read is moved aside
and replaced with an empty one; the app never fails to launch over data.

- **Settings**: typed keys over `UserDefaults`, exposed as one observable
  `SettingsStore`.
- **Dictionary**: `dictionary.json`. Entries, per-app limits, the ignore
  list for suggestions. 1000 entries at most.
- **Macros**: `macros.json`.
- **Run Log**: `history/index.json` and one 16 kHz WAV per entry. Twenty
  entries; older ones and their audio are deleted. It stores no app names.

## 8. Look and motion

Sorello follows the iPhone app. The app is always dark. Controls are
monochrome: white ink on near-black with a hairline edge. Colour marks only
small things that show a state.

| Token | Value | Use |
|---|---|---|
| aurora | `#6DFFA8` | The mark's dot: ready, live, done |
| glacier | `#67E8F9` | The wait's shimmer, and preparing |
| ember | `#F5C66B` | An error's symbol, never a dot |
| coral | `#FF7D5E` | Destructive actions only |
| screen | `#05080A` | Window background |
| card | `#0F1A1C` | Rows and cards |
| pill | `#09090A` | The pill and primary buttons, edged `#6E6E70` at 0.5 pt (1 pt with Increase Contrast) |
| toggle | `#3FD17A` | A switch that is on |

Display text (window titles, onboarding headlines) is Geist Serif Regular;
everything else is the system font. Text meets 4.5:1 on its background and
accents 3:1; `DesignCore` tests hold the palette to that.

### The pill

The pill is drawn in a borderless, non-activating panel above the menu bar
on the screen that has keyboard focus. It takes clicks only on its own
controls. Its shape depends on the screen's camera housing, read from
`NSScreen` (`safeAreaInsets`, `auxiliaryTopLeftArea`,
`auxiliaryTopRightArea`):

- **Island** (housing narrower than 110 pt; 59 x 40 pt on the 2026 MacBook
  Pro): a pure black capsule, 32 pt tall, centred on the housing, that
  grows sideways out of it. Leading wing: the wave, ending in the aurora
  dot beside the housing. Trailing wing: the elapsed time.
- **Notch** (wider housing): the same content in two wings inside the
  menu-bar band, drawn as one black shape flush with the top of the screen
  with rounded lower corners, so the notch appears to widen.
- **None** (external displays, older Macs): the iPhone island itself. A
  36 pt capsule in the pill colour with the hairline edge, 8 pt under the
  menu bar, centred.

Pure black is used where the body must merge with hardware. The geometry
for every form is one pure function in `DesignCore`, tested for each
housing. Island height and vertical offset can be nudged with two hidden
defaults, because `NSScreen` reports the housing's band, not its outline.

States:

- **Listening.** The dot wave (`DotWave`, ported with its tests): one row
  of white dots 6.2 pt apart showing the last 0.75 s of the voice, newest
  beside the aurora dot, which swells with the voice now. Levels come from
  `LevelMeter`, which follows the speaker's own range. In toggle mode a
  small cancel button buds off the pill and the pill itself is Stop. Prompt
  style shows a small tag glyph before the time.
- **Waiting.** The row at rest in glacier white with a brighter spot
  sweeping it every 1.1 s. With the model still preparing, the words
  "Preparing model" follow the row.
- **Notice.** The pill grows downward into a rounded card: a symbol (ember
  for errors), one line of white text, and at most two capsule actions.
  The dictionary suggestion ("Add 'Kubernetes'?" with Add and Dismiss) is
  a notice.

Motion: the body grows and shrinks on a spring (response 0.26 s, damping
0.88). At each change what leaves fades first, in 0.06 s, then what
arrives. The dots are Core Animation layers moved by a display link that
runs only while the pill is visible and animating, at most 60 frames a
second. With Reduce Motion nothing travels: states cross-fade in 0.15 s
and the wave stands still at each level.

### The mark

The Sorello mark is the wave coming to rest: a short row of dots rising
into the aurora dot. The app icon draws it on a near-black field. The
menu-bar icon is the same row as a template image.

### Windows

- **Menu panel**: state line with its dot, the shortcut hints, the last
  dictation with a copy button, then Dictionary, Run Log, Settings, Quit.
- **Main window**: a sidebar (General, Shortcuts, Dictionary, Macros, Run
  Log, About) over the screen colour, content in cards.
- **Setup**: welcome, microphone, Accessibility, shortcut, and a live test
  that shows the pill and the words.

Every screen has VoiceOver labels on its controls, because most controls
are icons. User-facing strings go through `String(localized:)`, so a string
catalog can be added without touching a call site. The app's name and
version are read from the bundle, never written in code.

## 9. Privacy and security invariants

A reviewer checks every change against these.

1. No network. No module imports a networking API or names a URL to
   contact. `scripts/check-rules.sh` fails the build on `URLSession`,
   `NWConnection`, `CFNetwork` or `WKWebView` in `Sources`.
2. No content in logs. Diagnostics go through one type, `Diagnostics`,
   whose events carry only enumerations, counts and durations. `print`,
   `NSLog`, `os_log` and `Logger` are banned elsewhere in `Sources`
   (checked by the same script), except in the two command-line tools.
3. Audio and transcripts exist in memory and in the Run Log, nowhere else.
   Clearing the Run Log deletes them.
4. Accessibility is used to post the paste, read the 16 characters around
   the cursor, and watch the pasted span for a correction for at most a
   minute. Secure fields are never read. Nothing read is stored.
5. The clipboard snapshot lives in memory for about a second.
6. Fixtures and tests contain only synthetic audio (`say`) and invented
   text.

## 10. Build, identity and model

- `swift build` and `swift test` build and test every module.
  `make check` runs both plus `scripts/check-rules.sh`; it needs no model
  and no network.
- `make app` assembles `build/<name>.app` with `scripts/build-app.sh`:
  the release executable, `Info.plist`, fonts, icon, notices and the model,
  then signs it with the hardened runtime and the audio-input entitlement.
  `CODESIGN_IDENTITY` defaults to ad hoc.
- Identity is one file, `Config/identity.env`. Development builds are
  "Sorello Dev", `com.audeolabs.sorello.dev`; `CHANNEL=release` builds are
  "Sorello", `com.audeolabs.sorello`. Minimum system: macOS 26, arm64.
- Model weights are not in Git. `Models/model.lock.json` pins the bundle by
  the SHA-256 of its manifest. `SORELLO_MODEL_DIR` points the build at a
  local copy, which is verified against the pin before it is copied in.
- The app is not sandboxed: the event tap and Accessibility calls do not
  work in the sandbox.

## 11. Testing and verification

- Tests use Swift Testing and are written against this contract before the
  code. They assert observable behaviour through public interfaces.
- The reducer is tested event by event, and through `SessionRuntime` with
  fake ports and a manual clock.
- `TextRules`, `DictionaryKit` and the chunker run the shared JSON vectors
  in `Tests/Vectors`.
- Engine tests that need the model run only when `SORELLO_MODEL_DIR` is
  set. `sorello-transcribe` checks a synthetic recording end to end.
- `SorelloSnapshots` renders each pill state for each housing, and each
  screen, to PNG. A change to anything visible is reviewed in those images.
- What tests cannot show (the event tap, the paste, the microphone, the
  pill over real hardware) is checked by running the app on a Mac.

## 12. Provenance

Sorello was written new. The session, shortcuts, capture, insertion, pill,
windows, storage and build were written from this document. The speech
runtime, dictionary, text rules and permission card were ported from code
written for LocalFlow by the same author; the permission card keeps the MIT
notices of the projects it adapts. The model's licence and attribution ship
in the app's resources.
