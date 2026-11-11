# Sorello for macOS: architecture contract

Sorello is a menu-bar dictation app for the Mac, on Apple silicon and on
Intel. You hold a key, speak, and release; the words appear at the cursor.
Speech recognition runs on the Mac, with a model Sorello downloads once,
during setup. That download is the only network connection Sorello makes.

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
  while the shortcut is down. Tapping it twice starts a hands-free
  dictation instead, which goes on until it is tapped once more. *Tap to
  Toggle* starts on one press and stops on the next. Audio is transcribed
  while it is recorded, in 15 second chunks, so the wait after release
  covers only the last chunk.
- **Show it.** A black pill at the top of the screen shows the voice as a
  row of dots while recording and a shimmer while the last words are
  transcribed (section 8). It drops down just below the menu bar, under
  the camera island or notch on a Mac that has one.
- **Insert.** The text is pasted at the cursor. The previous clipboard is
  restored afterwards unless the user turns that off. *Paste Again* inserts
  the last dictation again.
- **Fit.** Just before pasting, up to 16 characters on each side of the
  cursor are read so that a dictation placed inside a sentence is
  lowercased and loses redundant final punctuation. Nothing read is kept.
- **Rules, not a language model.** Spoken numbers become digits. Voice
  macros replace a complete spoken phrase with saved text. A trailing
  "press enter" presses Return after the paste. Prompt style prefixes the
  text with a tag so an AI agent knows it was dictated; the double tap of
  Hold to Talk can be set to start one, in place of a hands-free dictation.
  All of these are small deterministic rules.
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
| `DictionaryKit` | neutral | nothing | Entries, validation, tokenizer, bias graph, casing, correction decisions and the correction watch, the `TextFieldReading` protocol it reads text through, the dictionary file |
| `DesignCore` | neutral, pure | nothing | Palette, dot wave, level meter, pill geometry, motion constants, the mark |
| `SpeechEngine` | neutral | `DictationCore`, `DictionaryKit` | The model's pin, download and store, feature front end, Core ML encoder, decoder, chunked streaming |
| `Persistence` | neutral | `DictationCore`, `TextRules` | Settings, macros, Run Log |
| `SorelloUI` | macOS UI | `DesignCore` | The pill, its overlay window, every screen and control |
| `MacPlatform` | macOS | `DictationCore`, `DictionaryKit` | Shortcuts, audio capture, text insertion, Accessibility reads, permissions |
| `SorelloApp` | macOS | all of the above | Composition: builds the objects, connects them, owns windows and the menu bar item |
| `Sorello` | executable | `SorelloApp` | `@main` only |
| `SorelloSnapshots` | executable | `SorelloUI` | Renders every pill state and screen to PNG files |
| `sorello-transcribe` | executable | `SpeechEngine` | Transcribes a WAV file with the real model, and downloads the model as the app does, for verification |

Rules the compiler enforces through the package graph:

- Pure modules import only Foundation (and CoreGraphics types where
  geometry needs them). They never import AppKit, SwiftUI, AVFoundation or
  CoreML.
- `SorelloUI` knows nothing about speech, storage or the session. It draws
  values it is given and reports actions through closures. `SorelloApp`
  maps session state to those values.
- Adapters depend on the neutral modules, never the reverse, and never on
  each other.
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

Two things are deliberately outside `reduce`:

- **Resources.** Dropping a stale event must never leak the microphone or a
  stream. The runtime runs one task per dictation; cancelling the dictation
  cancels the task, and whatever that task holds or is about to receive (a
  capture that finished starting late, an open stream) is released by the
  task itself. Decisions are the reducer's; cleanup is the runtime's.
- **Audio.** Samples and levels never pass through the state.

`TriggerHandling.handle` runs `reduce` and returns. Effects are performed
after it returns, and nothing in it waits for Accessibility, capture,
speech or the disk, because it is called from the keyboard event tap.

### State

```
SessionState
  capture:    idle | awaitingPermission(intent?) | starting | recording
  pipeline:   [dictation]  audio stopped; each is draining, transcribing, ready or inserting; oldest first
  output:     free | inserting(DictationID) | replaying(ReplayID)
  microphone: unknown | granted | denied
  engine:     preparing | ready | failed
  notice:     Notice?      one short message for the pill, with its own id
  last:       the last inserted text, for Paste Again
  tap:        the double tap's arm, if any
```

At most one dictation uses the microphone, and at most three exist at once
(the one recording plus the pipeline). A second dictation can start while
the first is still being transcribed; text is inserted in the order it was
spoken, one insertion at a time.

### Events

- Triggers: `holdPressed`, `holdReleased(origin)`, `holdAbandoned`,
  `togglePressed`, `cancelPressed`, `pasteAgainPressed`, `pillStopClicked`,
  `pillCancelClicked`, `systemInterrupted`. Each carries the monotonic
  time it arrived. `origin` is `keyUp` or `interrupted` (the shortcut
  ended without a genuine key release). `holdAbandoned` means the hold
  turned out to be the start of a chord. `systemInterrupted` means the
  session was locked or switched away, or the Mac is going to sleep.
- Capture, each with its `DictationID`: `started`, `failed(reason)`,
  `stalled`, `interrupted(reason)`, `ended(summary)`.
- `transcript(id, result)`, `insertion(id, report)`,
  `reinsertion(replayID, outcome)`, `timer(timerID)`,
  `microphoneAccess(access)`, `engine(readiness)`.

### Effects

- `requestMicrophoneAccess`
- `startCapture(id)` and `openStream(id, options)`
- `stopCapture(id)`: finish, and deliver what was heard
- `abortCapture(id)`: stop producing audio now; what was already delivered
  still counts
- `finishStream(id)`
- `discard(id)`: throw the dictation away. Its task is cancelled, its
  capture and stream are released, its audio is dropped, and nothing of
  it is transcribed or inserted.
- `insert(id)` and `reinsert(replayID, text)`
- `setTimer(timerID, after)` and `cancelTimer(timerID)`
- `record(entry)`: the Run Log

Timers are typed: `captureStart(id)`, `captureDrain(id)`,
`captureLimit(id)` and `notice(noticeID)`. A timer event is acted on only
if that exact timer is still armed, and a dictation that leaves a phase
cancels that phase's timer.

### Rules

1. **Start.** A hold or toggle press while `capture` is `idle` starts a
   dictation: allocate the id, `startCapture`, `openStream`, and set
   `captureStart(id)` for 3 s, which includes any wait for the previous
   capture's teardown. The text options and the app in front are read
   once, now, and stay with the dictation. If three dictations already
   exist, show the busy notice and start nothing. If the microphone is
   `denied`, show the microphone notice and start nothing. If the engine
   has `failed`, show the engine notice and start nothing. An engine that
   is still `preparing` does not block recording: the transcript waits
   behind preparation.
2. **Permission.** If the microphone is `unknown`, the press requests
   access and `capture` becomes `awaitingPermission` holding the intent:
   the mode, the press time and, for a hold, that the key is down.
   Releasing or abandoning that hold, a second toggle press, Escape or
   `systemInterrupted` clears the intent; a new press replaces it. When
   access is granted, an intent that is still there starts a dictation as
   in rule 1. A granted result never revives a press that was released. A
   denied result clears the intent and shows the microphone notice.
3. **Recording.** `capture.started` moves `starting` to `recording`,
   cancels the start timer and sets `captureLimit(id)` for 15 minutes. A
   stop that was asked for during `starting` is applied now.
4. **Stop.** Releasing Hold to Talk, pressing Tap to Toggle again, tapping
   Hold to Talk during a toggle recording (rule 5), clicking the pill in
   toggle mode, the limit timer, `systemInterrupted`,
   `stalled`, `interrupted` and `capture.failed` while recording all do
   the same thing: `stopCapture`, cancel the limit timer, set
   `captureDrain(id)` for 2 s, move the dictation into the pipeline as
   `draining`, and make `capture` `idle`. The microphone can be asked for
   again at once; the capture adapter finishes one capture's teardown
   before it starts the next.

   `capture.ended` is the only thing that finishes a draining dictation.
   It cancels the drain timer and moves the dictation to `transcribing`
   with `finishStream`, unless less than 0.15 s of audio was captured, in
   which case the dictation is discarded and nothing shown. If the drain
   timer fires first it sends only `abortCapture`: the capture stops
   producing at once, the consumer still appends every chunk that was
   already delivered, and `capture.ended` then arrives as usual. A
   capture event for a dictation that is not `starting`, `recording` or
   `draining` does nothing, even though the dictation still exists.
5. **Double tap.** What a double tap of Hold to Talk does is a setting:
   a hands-free dictation (the default), a prompt, or nothing. Unless it
   is nothing, a hold released within 0.3 s of its press, by the triggers'
   own timestamps and whether it was `starting` or `recording`, is
   discarded and arms the tap. A Hold to Talk press within 0.4 s of that
   release uses the arm up and starts what the setting says at that
   moment: hands-free starts a toggle recording, prompt starts a hold in
   prompt style. The tap arms only if nothing at all was in progress when
   it was pressed and it ended with a genuine `keyUp`. Any other trigger,
   an abandoned hold, or a permission request clears the arm.

   A hands-free recording is a toggle recording like one Tap to Toggle
   started. Releasing the press that started it does nothing, and whatever
   stops or cancels a toggle recording stops or cancels it. If that press
   turns out to be the start of a chord (`holdAbandoned`), the recording
   is discarded like any abandoned hold.

   Hold to Talk stops a toggle recording, however it was started. A press
   that arrives while the recording is `starting` or `recording`, and is
   then released with a genuine `keyUp` while the recording is still
   there, stops it as in rule 4, at the release. If that press is
   abandoned as a chord or ends `interrupted`, nothing happens and the
   recording goes on. Such a press never arms the tap.
6. **Cancel.** Escape, or the pill's cancel button:
   - with a dictation `starting` or `recording`, discards that dictation
     and leaves the pipeline alone;
   - otherwise, discards every pipeline item that is not `inserting`,
     draining ones included. An item that is inserting, and a replay, are
     left alone, even while they wait for modifiers: a paste is never
     retracted;
   - while awaiting permission, clears the intent.

   `handle` reports true, and Escape is consumed, only if something was
   cancelled.
7. **Other triggers.** A toggle press during a hold recording is ignored.
   A hold press during a toggle recording starts nothing: it can only stop
   that recording (rule 5). `holdAbandoned` discards
   the hold's dictation like a cancel, with no notice. A hold release with
   no hold in progress is ignored, so a key still down after the 15 minute
   limit starts nothing until it is pressed again. `systemInterrupted`
   stops a recording in either mode as in rule 4 and discards a dictation
   that is still `starting`. Nothing resumes by itself when the session
   comes back.
8. **Order.** `transcript(id, result)` with empty text removes the item;
   if the recording lasted a second or more, the "nothing heard" notice is
   shown. Otherwise the item is `ready`. Whenever `output` is `free` and
   the oldest pipeline item is `ready`, the reducer claims `output` and
   emits `insert(id)`. Later items wait for it, even if they were ready
   first.
9. **Insertion.** Every `insertion(id, report)` frees `output`, removes the
   item, and applies rule 8 again. `inserted` and `leftOnClipboard` record
   the Run Log entry and, when the text is not empty, remember it for
   Paste Again; `leftOnClipboard` also shows a notice telling the user to
   paste. A dictation that only pressed Return leaves the remembered text
   as it was. `nothingToInsert` (a macro whose saved text is empty) does
   nothing more. `failed` records the entry and shows an error notice; a
   "press enter" that could not be posted says so. Once a paste has been
   posted for a dictation, nothing is ever posted for it again
   automatically.
10. **Failures.** The start timer firing in `starting`, or
    `capture.failed` in `starting`, discards the dictation and shows the
    microphone-unavailable notice. A failed transcript removes its item,
    records the entry with its audio so it can be retried, and shows an
    error notice. An engine that fails while a dictation records does not
    interrupt it; its transcript fails in the ordinary way.
11. **Paste Again.** When `capture` is `idle`, the pipeline is empty,
    `output` is `free` and there is a last text, the reducer claims
    `output` as `replaying` and emits `reinsert`. `reinsertion` frees it.
    A replay pastes the same text, never presses Return, is not recorded,
    and is never watched for a correction. If the text was left on the
    clipboard or could not be pasted, the same notice as in rule 9 says
    so.
12. **Notices** expire by their own timer: 1.4 s for information, 4 s for
    errors. Starting a dictation dismisses the notice.

When a dictation leaves the session, the runtime also reports a
`DictationCompletion` to the app: its id, how it ended, the speech result
if there was one, and the processed text and flags if composition ran.
Clearing the Run Log also makes the session forget the remembered text.

### What the pill shows

`PillContent` is a pure function of `SessionState`: `listening` while
starting or recording; otherwise an error `notice`; otherwise `waiting`
while the pipeline is not empty (with the reason `preparingModel` when the
engine is not ready); otherwise an information `notice`; otherwise
`hidden`. Nothing is shown while awaiting permission: the system's prompt
is on screen. The runtime hands each captured chunk, with its time and its
dictation, to a `LevelSink`, and the pill reads the level from there.

## 4. Ports

Defined in `DictationCore/Ports.swift`. Each is small enough to fake in a
test.

| Port | Implemented by | Purpose |
|---|---|---|
| `AudioCapturing`, `AudioCapture` | `MacPlatform` | Start a capture; deliver 16 kHz mono `Float` chunks to one consumer, in order and without dropping; stop or abort |
| `SpeechTranscribing`, `SpeechStreaming` | `SpeechEngine` | Prepare the model, report readiness, open a stream, append samples, finish with text, cancel |
| `TranscriptProcessing` | `SorelloApp` over `TextRules` | An immutable snapshot of the user's text rules: transcript, style and insertion context in; text to insert out |
| `TextInserting` | `MacPlatform` | Run one insertion: find the destination, read the text around the cursor, ask the caller to compose the text for it, paste; report the outcome |
| `MicrophoneAuthorizing` | `MacPlatform` | Current access, and a request |
| `FrontmostAppReading` | `MacPlatform` | Bundle identifier and name of the app in front, read when a dictation starts |
| `HistoryRecording` | `Persistence` | Save a Run Log entry and its samples |
| `LevelSink` | `SorelloApp`, over `SorelloUI`'s level feed | Hear each captured chunk with its time, to show the voice |
| `SessionClock` | `DictationCore` | Monotonic now, and sleeping; a manual clock in tests |

`TextFieldReading`, the bounded Accessibility reads used by insertion and
by the correction watch, is declared in `DictionaryKit` and implemented in
`MacPlatform`. No Accessibility type enters `DictationCore`.

How the runtime uses them:

- **Capture.** `start` honours task cancellation: it either throws after
  releasing the microphone or returns one live capture. A capture returned
  to a dictation that has since been discarded is aborted by the runtime at
  once. One consumer reads `events`, appends each chunk to the speech
  stream and to the recording kept for the Run Log, and reports
  `capture.ended` exactly once, only after the stream of events has
  finished and every delivered chunk has been appended. `abort` closes the
  stream at once: chunks already delivered stay readable, anything not yet
  delivered is dropped. `events` buffers without limit and never drops
  audio; the 15 minute limit bounds it. The level sink follows the newest
  dictation only: once it has heard a chunk from a newer dictation it
  ignores everything from an older one, so a draining dictation's last
  chunks never disturb the wave. That filter is for the picture only; the
  audio still reaches speech and the Run Log.
- **Speech.** A stream is its own object with a synchronized ingress, so
  `append` and `cancel` are plain synchronous calls that never wait for the
  model. `finish` is called once; `cancel` wins over it and makes a pending
  `finish` throw `cancelled` promptly. If preparation fails, every waiting
  `finish` throws `engineUnavailable`; `prepare` called again starts a new
  attempt, and concurrent calls share one. `failed(.modelMissing)` means
  no model is on the Mac yet. A new attempt looks for it again, so the
  engine becomes ready without a relaunch once the model has arrived
  (section 5).
- **Text.** The processor is a snapshot taken when the dictation starts, so
  editing a macro while a dictation waits changes nothing for it. Insertion
  context is read only when the dictation reaches the head of the pipeline,
  after the text before it has landed.
- **Insertion.** `insert` takes a `compose` closure. The adapter waits for
  the shortcut's modifiers, finds the destination, reads the context, and
  only then calls `compose` exactly once, telling it where the text is
  going: to the cursor (with the context, and a token naming the field and
  selection that were read) or only to the clipboard (with the reason).
  `compose` runs the text rules and returns the text and whether to press
  Return. The runtime passes the token, unopened, to the app's hook, and
  the correction watch takes its anchor from it; it never looks for the
  focused field itself. A clipboard-only composition and a replay give no
  token, so they are never watched. Only a dictation reported `inserted`,
  typed rather than pasted from a macro, without Return, with a correction
  id and a token, starts a watch; every other ending releases the anchor.

## 5. Speech engine

Ported from LocalFlow's runtime, which was measured and tuned there:

- The model is kea-b-0.1, a 1-bit derivative of NVIDIA Parakeet v2, as a
  Core ML encoder with one 15 second function, a vDSP feature front end
  and an Accelerate TDT decoder. English only.
- Where the encoder runs is read from the hardware once, when the engine
  is made (`MLComputeDevice.allComputeDevices`), never from the
  architecture the app was built for. On a Mac with a Neural Engine it
  runs there (`cpuAndNeuralEngine`). On a Mac without one, which is every
  Intel Mac, Core ML's CPU kernels are the fallback (`cpuOnly`): the same
  model files, the same chunks, front end and decoder, only slower and
  with the weights unpacked in memory. The GPU is not used: nothing about
  it can be checked on the Macs Sorello is built on. The two paths may
  differ where two words score almost alike, as 16-bit and 32-bit
  arithmetic do. The General screen says which one this Mac uses.
  `sorello-transcribe --cpu` and `Sorello --self-test --cpu` force the
  fallback, so it can be proved on any Mac.
- `SpeechEngine` is an actor with its own serial executor. Model loading,
  warm-up and every prediction run there, one at a time. `append` on a
  stream never waits for model work.
- The model is loaded from the store,
  `Application Support/<bundle id>/Models/<hash>`, one directory named by
  the SHA-256 of the model's manifest, because
  Core ML's Neural Engine cache is keyed by the model file's path and
  identity: a copy that is never rewritten stays warm across app updates
  that keep the model. Each file's SHA-256 is checked against the
  manifest before loading. The CPU fallback loads the same copy, so both
  paths share one store and one check. The manifest's `compute_units`
  records how the model was exported; nothing reads it. How the model
  gets into the store is under "Getting the model" below.
- Audio is cut into 15 s chunks that overlap by 2 s and are joined on a
  word both chunks heard. Long silences are compacted first. The shared
  vectors in `Tests/Vectors` pin this behaviour, as they do on Linux.
- Preparation starts at launch, and again when a download has put the
  model in the store. The first preparation on a machine can take minutes
  on the Neural Engine, which compiles the model for itself; the fallback
  takes seconds every time. The menu and the General screen show its
  state and offer a retry after a failure.
- The dictionary biases decoding through a graph built per dictionary
  revision and app. `docs/dictionary/DESIGN.md` is the contract for
  entries, validation, boosting and correction suggestions.
  Where that document and this one disagree about where the dictionary is
  stored or what happens to an unreadable file, section 7 here wins.
- For correction suggestions the engine keeps what it needs to decode one
  dictation again, in memory only: the most recent one that asked for it.
  A late result from an older dictation never replaces a newer one's.
  Starting a new recording, clearing the Run Log, or the watch ending
  releases it.

### Getting the model

The app does not carry the model. `Models/model.lock.json`, the pin, ships
in the app as `Contents/Resources/model.lock.json`, and it is all Sorello
knows about where the model is and what it must be:

- `source`: the address the model's files are under, at one fixed revision
  of the model's repository on Hugging Face.
- `builds`: each is a directory under `source` that holds one complete
  model. A build gives the SHA-256 of its `bundle.json`, its size in
  bytes, and what it `requires` of the Mac. The only requirement today is
  `macos`, the lowest system version it runs on.

Sorello uses the first build whose requirements this Mac meets. A build
that requires something this version of Sorello does not know is passed
over, so a later pin can list builds for other Macs (an older system, a
Mac without a Neural Engine) and an app that has never heard of them
takes none of them by mistake. One build is listed today, for macOS 26 or
later; a Mac without a Neural Engine runs that same build on its
processor until it has a build of its own. Builds for other Macs wait on
other branches of the model's repository until they have been tested, and
join the list then: nothing else in Sorello changes when one does. When
no build fits this Mac, Sorello says so and offers no download.

Where the engine looks, in order: the store; then the app itself, when it
was built with `SORELLO_MODEL_DIR` and so carries a build the pin lists
that this Mac meets, which is copied to the store once, under the store's
file lock; otherwise the model is absent. Then the engine reports
`failed(.modelMissing)`, and it looks again each time it is asked to
prepare. Once the pinned model is complete in the store, everything else
there is removed. A stored copy whose files do not match its manifest is
removed when the engine loads it; without a copy in the app, the model is
then absent again, and the download is offered again.

The download:

- **Only when asked.** It starts when the user presses Download, in setup
  or on the General screen, and at no other time: not at launch, not on a
  timer, and not again by itself after it fails or the app quits.
- **What is fetched.** `bundle.json` first, which must have the SHA-256
  the pin gives. Then every file it lists, at the path it lists, each
  checked against the manifest's SHA-256 when it is complete. A path that
  is absolute or leaves the build's directory is refused. A file that
  fails its check is deleted and the download fails. Sorello never writes
  more bytes than the pin says the build has.
- **Where it goes.** Into a directory of its own inside the store, which
  outlives the app quitting. One process at a time downloads into it;
  another waits for it, and then usually finds the model there. When every file is there and checked, that
  directory becomes the stored model in one rename, under the store's
  lock, as a copy from the app does, and the engine is asked to prepare.
  Nothing is loaded from a download that has not finished, and the engine
  checks every file again when it loads.
- **Stopping and going on.** Cancel stops at once. A download that was
  cancelled, failed, or cut off by quitting goes on from what it has when
  the user starts it again: finished files are not fetched again, and a
  part of a file is continued with a range request when the server
  honours it, and fetched from its start when it does not.
- **What the user sees.** The bytes received out of the build's size, and
  when it fails, why, in one of four plain sentences: there is no
  connection or it dropped; the server did not provide the model; what
  arrived did not pass its check; the disk is full. None carries an
  address or a file name.
- **The connection.** HTTPS only, to `source` and to wherever its host
  redirects, at most five times and only to HTTPS. One session with no
  cookies, no cache and no stored credentials. Each request is a GET with
  `User-Agent: Sorello/<version>`, `Accept-Language: en`, and `Range` when
  it continues a file; Sorello adds nothing else. A connection that is
  silent for 30 seconds is given up as dropped.

## 6. macOS adapters

### Shortcuts

- A binding is either a key with optional modifiers, or a set of modifier
  keys alone (left and right distinguished; Fn is a modifier here).
  Defaults: Hold to Talk is Fn; Tap to Toggle and Paste Again are unset.
  A binding cannot be empty, cannot be Escape, cannot be a bare typing key,
  and cannot repeat another action's.
- One active event tap at the session level, on the main run loop, reads
  key and modifier events. Its callback only normalizes the event, runs the
  matcher and calls `handle`; it never waits. It needs Accessibility.
  Without it the adapter reports `needsAccessibility` and no shortcut
  works.
- A key binding consumes its own key-down, its repeats and its key-up, and
  always consumes the key-up of a key-down it consumed. Auto-repeat never
  triggers anything; an action triggers again only after a fresh key-down.
  A modifier-only binding consumes nothing and matches only while exactly
  its keys are down, tracked per physical key.
- A modifier-only hold starts at once. If another key goes down within
  0.3 s the hold was a chord: `holdAbandoned`.
- A hold ends as `holdReleased(interrupted)` when the system disables the
  tap (the adapter enables it again), when secure input begins, or when
  the bindings change under it. While secure input is on, the adapter
  reports that shortcuts are paused.
- When the session is locked or switched to another user, and when the Mac
  is about to sleep, the adapter sends `systemInterrupted`, whatever the
  shortcut mode, so a toggle recording does not go on behind a lock
  screen.
- Escape is delivered as `cancelPressed` and consumed only when `handle`
  returns true.
- Events Sorello posts itself carry a fixed tag and are ignored by the tap.
- The shortcut recorder in Settings reads the next key or modifier set from
  the same tap. While it records, shortcut matches deliver no triggers.
  `systemInterrupted` comes from system notifications, not from the tap,
  and is still delivered while the recorder is open, while shortcuts are
  paused, and when the tap could not be created at all.
- The Fn key also has a system action (emoji, input source or dictation).
  Setup explains how to set it to "Do Nothing"; Sorello never changes
  system settings itself.

### Audio capture

- `AVCaptureSession` with an audio data output on a private queue. The
  audio engine's input tap is not used: with some Bluetooth and aggregate
  devices it delivers no buffers.
- The input is the system default, or a microphone chosen in Settings and
  found again by its unique identifier (the default is used if it is
  gone). Samples are converted to 16 kHz mono `Float`. A format change
  mid-capture rebuilds the converter; `stop` flushes the converter's tail.
- The microphone is held only from `start` until `stop` or `abort` has
  torn the session down. Starts and teardowns run one at a time, in the
  order asked. Audio stays in memory; nothing is written to disk until the
  Run Log entry is saved after insertion.
- `start` returns when the session is running and gives up after 3 s,
  which has to cover a Bluetooth headset switching profile. Opening a
  device blocks and cannot be interrupted, so when the 3 s pass during
  the open, `start` throws as soon as the open returns and the device has
  been released; the session's own timer has discarded the dictation by
  then. A capture that delivers nothing for 2 s reports `stalled` once. A
  device that goes away reports `interrupted`; any other error reports
  `failed`.

### Text insertion

One insertion is one transaction, and the adapter runs one transaction at
a time:

1. Wait, up to 1 s, until no Command, Option, Control or Shift key is
   down.
2. Decide where the text can go. If a modifier is still down
   (`modifiersStillDown`), the screen is locked or this user's session is
   not the active one or is going to sleep (`screenLocked`), or the app
   has no Accessibility (`accessibilityMissing`), it can go only to the
   clipboard: nothing will be posted, and no field is read.
   Otherwise find the focused field of the app in front and read up to 16
   UTF-16 units each side of the selection (nothing, for a secure or
   unreadable field; the paste still goes ahead).
3. Call `compose` once, with that destination. Then classify what it
   returned, before touching the clipboard:
   - no text and no Return: `nothingToInsert`;
   - clipboard only, with text: write the text plainly and report
     `leftOnClipboard(reason)`;
   - clipboard only, with Return alone: write nothing and report
     `failed(commandNotPosted)`.
4. Check again immediately before posting the first key, because
   `compose` took time: this user's session is active, unlocked and not
   going to sleep; Accessibility is trusted; no Command, Option, Control
   or Shift key is down; the same app is in front; and, where it can be
   read, the prepared field still has focus and the same selection. If a
   check fails, no key is posted and the correction anchor is released.
   Text is left on the clipboard with the reason that applies
   (`screenLocked`, `accessibilityMissing`, `modifiersStillDown` or
   `targetChanged`); a lone Return is `failed(commandNotPosted)` and the
   clipboard is not touched. A field that cannot be read still gets a
   best-effort paste into the same app in front, without a correction
   watch. Sorello never brings another app forward to recover.
5. With text: if restoring, snapshot every item and type on the
   pasteboard. Write the text, marked transient when it will be restored
   so clipboard managers skip it, and remember the change count the write
   produced. Post Command-V with the key that types "v" under Command in
   the current layout (the ANSI V key if none does). Report `inserted`
   now: it means the paste was posted, which is all the system can tell
   us.
6. For Return after text: 80 ms after the paste, check again that the
   session is available, Accessibility is trusted, no modifier is down,
   the same app is in front and, where it can be read, the same field has
   focus (its selection has moved, because the paste moved it). If a
   check fails, skip Return; the paste that was posted is still
   `inserted`. A dictation that is only "press enter" posts Return alone
   under step 4's checks, without the wait, and leaves the clipboard
   untouched. If no key at all was posted the outcome is never
   `inserted`. Nothing is tried again on unlock, switch-back or wake.
7. If restoring: 1 s after the paste, put the snapshot back, but only if
   the pasteboard's change count is still the one from step 5. A snapshot
   that could not be taken in full, or is larger than 32 MB, is not
   restored. The next transaction starts only after this step.

If the caller is cancelled before any key is posted, the transaction
stops and reports `failed(cancelled)` once. If it had already written to
the clipboard, it puts the snapshot back only under step 7's conditions:
a complete snapshot within the size limit, and a change count that still
matches its own write. Otherwise it lets the clipboard be, without
another write. The next transaction waits until that is settled. After a
key is posted cancellation changes nothing: the adapter finishes the
guarded Return and the guarded restore on its own, and nothing is ever
posted twice.

Pasteboard access across apps cannot be made atomic; the change count is
what the system offers, and it is what protects something the user copies
in the meantime. Insertion sits behind `TextInserting` so another strategy
(typing, or per-app choices) can be added without touching the session.

### Accessibility reads and permissions

- `TextFieldReading` wraps the focused element: its selected range, its
  length and a substring. Every read is bounded; a whole value is never
  read. A field that is secure, or whose security cannot be determined,
  reads as nothing, and it is checked again before each read. Reads run on
  their own queue with a short per-message timeout and a total deadline of
  0.3 s for the insertion context; work that misses the deadline is
  abandoned, not waited for.
- Microphone access is requested the first time a dictation needs it.
  Accessibility is granted in System Settings; setup opens the pane with a
  card to drag in (adapted from Scrawl and AskForPermission, MIT, notices
  in `ThirdPartyNotices.md`).

## 7. Persistence

Everything is under `Application Support/<bundle id>/`, in a directory only
the user can read. Files are written atomically and carry a `version`. The
app never fails to launch over data: settings, the dictionary or macros
that cannot be read are moved aside and replaced with empty ones, and a Run
Log that cannot be read is deleted. A file that is there but cannot be
opened (a permission problem, not damage) is left alone: it is not deleted,
moved or written over, and its store works without it until it opens.

- **Settings**: typed keys over `UserDefaults`, exposed as one observable
  `SettingsStore`.
- **Dictionary**: `dictionary.json`. Entries, per-app limits, the ignore
  list for suggestions. 1000 entries at most.
- **Macros**: `macros.json`.
- **Run Log**: `history/index.json` and one 16 kHz WAV per entry. Twenty
  entries; older ones and their audio are deleted. It stores no app names.
  One writer serializes saving, deleting and clearing. An entry appears in
  the index only after its audio is on disk, and audio files with no entry
  are removed at launch. Clear removes the index and every audio and
  temporary file, and cancels any save that began before it. Retry
  transcribes an entry's audio again with today's dictionary and text
  rules and replaces the entry's words; it never pastes or presses a
  key. An entry goes on saying how it ended, so a retry never turns
  pasted words into a command alone, or a command into words: such a
  retry, like one that hears nothing or fails, leaves the entry as it
  was.

## 8. Look and motion

Sorello follows the iPhone app. Its windows and the pill are always dark.
Controls are monochrome: white ink on near-black with a hairline edge.
Colour marks only small things that show a state. The menu under the
menu-bar item is the one exception: it is the system's own (see Windows).

| Token | Value | Use |
|---|---|---|
| aurora | `#6DFFA8` | The mark's dot: ready, live, done |
| glacier | `#67E8F9` | The wait's shimmer, and preparing |
| ember | `#F5C66B` | An error's symbol, never a dot |
| coral | `#FF7D5E` | Destructive actions only |
| tangerine | `#FF9233` | Sorello Nightly's stars, on its app icon only |
| screen | `#05080A` | Window background |
| card | `#0F1A1C` | Rows and cards |
| pill | `#09090A` | The pill and primary buttons, edged `#6E6E70` at 0.5 pt (1 pt with Increase Contrast) |
| toggle | `#3FD17A` | A switch that is on |

Display text (window titles, onboarding headlines, the app's name) is
Urbanist, the typeface of the Audeo Labs site, set as the site sets its
headings: Medium, tracked in by 0.015 em. Everything else is the system
font. Text meets 4.5:1 on its background and accents 3:1; `DesignCore`
tests hold the palette to that.

### The pill

The pill is drawn in a borderless, non-activating panel at the status-bar
window level, on every Space and over full-screen apps. It appears on the
screen that has keyboard focus when the dictation starts (`NSScreen.main`;
failing that the screen under the pointer) and stays there for that
dictation; if that screen goes away it moves to the main one. The panel
that draws ignores the mouse entirely. Controls (stop, cancel, a notice's
actions) sit in a second small panel exactly the size of those controls,
shown only while there are any, so the pill never swallows a click meant
for the menu bar. Neither panel ever takes keyboard focus.

The pill is the iPhone island itself, on every screen: a capsule 36 pt
tall in the pill colour with the hairline edge, only as wide as what it
holds (about 160 pt while listening). It hangs 8 pt below the top band,
which is the menu bar, or the camera housing's band where that is taller.
Its middle is the housing's middle on a screen with a camera island or a
notch, and the screen's middle on one without. The housing is read from
`NSScreen` (`safeAreaInsets`, `auxiliaryTopLeftArea`,
`auxiliaryTopRightArea`) and counts only if both auxiliary areas exist and
leave a gap between them at the top of the screen. Its width changes
nothing: an island and a notch get the same pill. From its leading end
the pill holds the wave, ending in the aurora dot, then the elapsed time.

The pill never draws in the top band, so it cannot cover the menu bar,
the camera housing or anything the system shows around it. It drops down
from the band: it starts as a small capsule touching the foot of the
band, under the housing, and grows down and outward to its place, fading
in as it grows. What it holds, and the cancel bud, follow once it has
nearly dropped into place. It leaves the same way, back up, after what
it holds has faded.

The geometry is one pure function in `DesignCore`: the display (frame, top
band, housing span, scale) and the content's measured sizes go in; the
body's outline, the regions for the wave, the text and each control, and
the interactive regions come out, in whole pixels. The same content gives
the same body on every screen wide enough for it, placed by that screen's
band and middle. A body too wide for the screen is narrowed to fit it:
the wave gives way first, then text is truncated. While listening the
body holds still as the seconds tick, and widens only when the time gains
a digit. `SorelloSnapshots --demo` shows the real pill on the real screen.

States:

- **Listening.** The dot wave (`DotWave`, ported with its tests): one row
  of white dots 6.2 pt apart showing the last 0.75 s of the voice, newest
  beside the aurora dot, which swells with the voice now. Levels come from
  `LevelMeter`, which follows the speaker's own range. In toggle mode,
  hands-free included, a small cancel button buds off the pill and the
  pill itself is Stop. Prompt style shows a small tag glyph before the
  time.
- **Waiting.** The row at rest in glacier white with a brighter spot
  sweeping it every 1.1 s. With the model still preparing, the words
  "Preparing model" follow the row.
- **Notice.** The pill grows downward into a rounded card: a symbol
  (ember for errors), one line of white text, and up to four capsule
  actions. They share one row while they fit; otherwise they take the
  fewest rows that hold them, so no title is cut short unless it alone is
  wider than the card. The dictionary suggestion is a notice owned by the
  app layer, with the actions and the lifetime
  `docs/dictionary/DESIGN.md` gives it: four actions when the dictation
  had an app, three when it had none.

Motion: the body grows and shrinks on a spring (response 0.26 s, damping
0.88). At each change what leaves fades first, in 0.06 s, then what
arrives. What leaves stays where it was drawn while it fades, whatever
size the next form is and however the panel grows to hold it. The dots
are Core Animation layers moved by a display link that runs only while
the pill is visible and animating, at most 60 frames a second. With
Reduce Motion nothing travels: states cross-fade in 0.15 s, the wave
stands still at each level, and the wait is a still row with its middle
dot lit. VoiceOver sees the pill's controls as "Stop dictation" and
"Cancel dictation" and announces a notice once; the moving level is never
exposed to it.

### The mark

The Sorello mark is the wave coming to rest: a short row of dots rising
into the aurora dot. The app icon draws it on a near-black field. The
menu-bar icon is the same row as a template image. Setup's welcome and
About show it at rest in the island's capsule: the row's ink is centred in
the capsule both ways, and the aurora dot's glow is drawn around that dot
without moving anything.

Sorello Nightly's icon is that icon with a few small orange stars on the
field, around the mark and clear of it and of the aurora dot's glow, so a
nightly is told from a release at a glance in the Dock, the app switcher
and Finder. The stars are always in the same places. Nothing else about a
nightly looks different: its menu-bar icon, setup and About show the mark
as every build does, and a development build has the plain icon.
`Resources/AppIcon-Nightly.icns` holds the nightly's icon, and a nightly
build carries it as its icon.

### Windows

- **Menu**: the menu-bar item opens an ordinary menu. The system draws
  it, in its own material, font and light or dark appearance. Sorello
  gives it no colours, no rows drawn by hand and no window of its own.
  From the top:
  - the state line with its dot, which is not a command, and under it the
    command that mends the state when there is one (Retry for a model
    that failed to load, the General screen for a permission or for a
    model to download);
  - under the heading Shortcuts, the three shortcuts, each with its keys
    at the trailing edge of its row, or "Not set" there. Choosing one
    opens the Shortcuts screen;
  - Copy Last Dictation, which is unavailable until there is a dictation
    to copy;
  - Dictionary, Run Log, Settings (⌘,) and Quit (⌘Q).

  The rows are one function of the values the windows show, made again
  each time the menu opens and kept current while it is open.

  The menu never shows what was dictated. No row carries a dictation's
  text, and the menu is told only whether there is one to copy. So it is
  as wide as its own rows and their keys need, like any other menu.
- **Main window**: a sidebar (General, Shortcuts, Dictionary, Macros, Run
  Log, About) over the screen colour, content in cards.
- **Setup**: welcome, the speech model, microphone, Accessibility,
  shortcut, and a live test. The model's step is there only when the
  model is not on the Mac as setup opens, and then it stays for that
  setup. It says how large the download is and that nothing said to
  Sorello leaves the Mac; the General screen says where it comes from.
  Its button starts the download. Once it has started, the user
  can go on, and it continues behind the later steps. The test has a text
  field of its own with keyboard focus, so the dictation is pasted there
  by the ordinary path and nowhere else; until the model is ready, the
  test says what it is waiting for. At launch, a model that is absent and
  can be downloaded opens setup at its step, as a missing permission
  opens it at that permission's.
- **The model's state** is said the same way wherever it shows. Ready,
  preparing and failed to load are as they were. When the model is not on
  the Mac, the menu's state line says "Speech model not downloaded" and
  its command opens the General screen, where the model's row says how
  large the download is and has a Download button. While it downloads,
  the row shows how much has arrived, as a bar and in words, with a
  Cancel button, and the menu says "Downloading speech model". When it
  fails, the row says why and offers Try Again. When no build fits this
  Mac, each says there is no speech model for this Mac yet and offers
  nothing. A dictation begun without the model ends in a notice that says
  the model has not been downloaded.

The main window and setup have the sizes their chrome gives them
(`WindowChrome`), and what a window shows never changes them. Each opens
at its default size. The main window can be resized, down to its minimum
and no further. Setup cannot be resized: it is one size at every step and
in every state, so its buttons are always where they were. A notice's
window opens at one size and can be made no smaller than its own minimum.

Sorello lives in the menu bar. With none of its windows open it has no
Dock icon and is not in the app switcher. While setup, the main window or
a notice's window is open, it is an ordinary app: its icon is in the Dock,
it is in the app switcher, and its menus (its own, Edit and Window) are in
the menu bar while it is in front. So a window of Sorello's comes back the
way any app's does: from the Dock, with Command-Tab, and after the system
has shown a prompt of its own. A minimised window is still open. When the
last window closes, Sorello leaves the Dock and, if it was in front, asks
for the app that was in front before it to come forward, if that app is
still running. That is a request, which the system may refuse: Sorello
then stays in front, without a window, until the user goes elsewhere. It
never hides itself to give up the front. Clicking the Dock icon, or
opening Sorello again, brings forward the windows that are open, and opens
the main window only when none is. The pill, the Accessibility card and
the system's own panels are not windows in this sense: they never put
Sorello in the Dock, and a dictation never brings Sorello forward. Hiding
Sorello, from its menu or from another app's Hide Others, hides its
windows. The pill and the Accessibility card are kept out of that: one
that is showing stays where it is. When a window asks for the microphone,
that window is in front again once the system's prompt has been answered.

Every screen has VoiceOver labels on its controls, because most controls
are icons. User-facing strings go through `String(localized:)`, so a string
catalog can be added without touching a call site. The app's name and
version are read from the bundle, never written in code.

## 9. Privacy and security invariants

A reviewer checks every change against these.

1. One connection, for the model. Sorello opens a network connection only
   to download its speech model (section 5, "Getting the model"), and
   only when the user asks for it. It sends nothing about the user, the
   Mac or what was dictated: the server learns the address the request
   came from and which build was asked for. Nothing downloaded is used
   before its SHA-256 matches the pin. `URLSession` is named in one
   source file, `Sources/SpeechEngine/ModelDownloader.swift`. No other
   source opens a connection, and no source names a host: the address is
   in `Models/model.lock.json`.
2. No content in logs. Diagnostics go through one type, `Diagnostics`,
   whose events are a compile-time name and numbers. `print`, `NSLog`,
   `os_log` and `Logger` are not used elsewhere in `Sources`, except in
   the two command-line tools. The app itself writes to standard output
   only in its two verification modes, `--self-test` and `--snapshots`,
   which report on synthetic recordings to the person who ran them.
3. In storage Sorello manages, audio and transcripts exist only in the Run
   Log. Clearing it deletes them and makes the app forget the last
   dictation and any audio kept for a correction suggestion. What a
   destination app, a backup or a clipboard manager keeps is outside
   Sorello's control.
4. Accessibility is used to post the paste, read the 16 units around the
   cursor, and watch the pasted span for a correction for the bounded time
   the dictionary design allows. Secure fields are never read. What is
   read is held in memory for that long and then released; only a
   suggestion the user accepts becomes a dictionary entry.
5. The clipboard snapshot lives in memory for about a second.
6. Fixtures and tests contain only synthetic audio (`say`) and invented
   text.

`scripts/check-rules.sh` is a lint for the first two and for module
purity. It catches the obvious mistakes; it does not prove the invariants.
Review does.

## 10. Build, identity and model

- `swift build` and `swift test` build and test every module.
  `make check` runs both plus `scripts/check-rules.sh`; it needs no model
  and no network.
- `make app` assembles `build/<name>.app` with `scripts/build-app.sh`:
  the release executable, `Info.plist`, fonts, icon, notices, the model's
  notices and the pin, then signs it with the hardened runtime and the
  audio-input entitlement. `CODESIGN_IDENTITY` defaults to ad hoc. A
  signature made with a certificate carries Apple's timestamp.
- Identity is one file, `Config/identity.conf`. There are three channels.
  Development builds are "Sorello Dev", `com.audeolabs.sorello.dev`;
  `CHANNEL=nightly` builds are "Sorello Nightly",
  `com.audeolabs.sorello.nightly`; `CHANNEL=release` builds are "Sorello",
  `com.audeolabs.sorello`. Each channel's app has its own data, model and
  permissions, so the three can be installed on one Mac; two that are
  running both answer the shortcuts. Minimum system: macOS 26, on Apple
  silicon or Intel.
- The version is `VERSION` in that file. The build number is `BUILD`
  there unless `BUILD_NUMBER` gives another, one to three whole numbers
  separated by dots. The workflows below give the number of commits in
  the history of the commit they build, so of two builds of `main` the
  later has the higher number. About shows both.
- A development build is made for the Mac that builds it. A nightly or
  release build is universal (arm64 and x86_64). `ARCHS` chooses
  otherwise, for example `ARCHS="arm64 x86_64"` for a universal
  development build. Each architecture is built on its own and joined
  with `lipo`; the build fails unless the signed executable holds exactly
  the architectures asked for.
- Model weights are not in Git, and in no channel does a build need them:
  the app downloads the build the pin lists for the Mac it runs on
  (section 5). `SORELLO_MODEL_DIR` is for a build that should carry the
  model and never download it. It points at a local copy; the build
  checks that copy's manifest against the pin's builds and every file
  against the manifest before copying it in, and fails otherwise.
- A bundled app loads its fonts, icon, pin and notices only from its own
  bundle, and its model only from the store. The repository's `Resources`
  directory and the `SORELLO_RESOURCES` override are used only by tests
  and the tools run from a build tree.
- The app is not sandboxed: the event tap and Accessibility calls do not
  work in the sandbox.

### Signed builds

- `scripts/notarize-app.sh <app> <zip>` has Apple notarize an app, staples
  the ticket to it, and writes the zip that is handed out. Before it
  uploads anything it refuses an app that is not signed with a Developer
  ID, the hardened runtime and Apple's timestamp. It writes no zip unless
  Apple accepts the app, the ticket is stapled, and Gatekeeper judges the
  app notarized. Notarizing uploads the app to Apple. The credentials are
  an App Store Connect API key, given in the environment.
- GitHub Actions runs the workflows in `.github/workflows` on GitHub's
  runners, on macOS with Xcode 27 for everything that builds. They use
  only GitHub's own actions, each pinned to a commit.
- **Check** runs `make check` on every pull request and on every push to
  `main`. A push to `main` is checked to the end, whatever is pushed
  after it.
- **Package** is what Nightly and Release share. It builds only a commit
  that is on `main` and whose push to `main` passed the check. It builds
  the channel's app signed with the Developer ID, notarizes it, and
  proves the app out of the zip: `--snapshots`, then `--self-test
  --download` with a recording made by `say`, whose words must come
  back. A build that fails any of this is not handed on.
- **Nightly** runs every night, and when it is started by hand. If `main`
  has not moved since the last nightly, it does nothing. Otherwise it
  packages "Sorello Nightly" from `main` and publishes it as the
  prerelease `nightly`, in place of the last one: one file,
  `Sorello-Nightly.zip`. The `nightly` tag is moved to the commit it was
  built from before the release is made on it, so a nightly is never
  published on a tag that is on another commit. If publishing fails part
  way there is no nightly until the next run, which builds again.
- **Release** is started by hand, from `main`. It packages "Sorello" and
  leaves `Sorello.zip` in a draft release named for the version, such as
  `v0.0.1`. Publishing the draft, which creates the tag, is the owner's.
  It fails, before anything is built, if that version already has a
  release, a draft or a tag.
- The Developer ID and the notarization key are repository secrets:
  `DEVELOPER_ID_P12` (the certificate and its key, a .p12 file in
  base64), `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8` (the API key, a
  .p8 file in base64), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. Only the
  job that builds reads them, the certificate from a keychain that exists
  for that job, and that job cannot write to the repository. The job that
  publishes has none of them. Without them nothing is published: there is
  no unsigned nightly.

## 11. Testing and verification

- Tests use Swift Testing and are written against this contract before the
  code. They assert observable behaviour through public interfaces.
- The reducer is tested event by event, and through `SessionRuntime` with
  fake ports and a manual clock.
- `TextRules`, `DictionaryKit` and the chunker run the shared JSON vectors
  in `Tests/Vectors`.
- Engine tests that need the model run only when `SORELLO_MODEL_DIR` is
  set. `sorello-transcribe` checks a synthetic recording end to end.
- The download is tested against a transport of the tests' own, which
  serves, stalls, cuts off, redirects and sends the wrong bytes. No test
  opens a connection. Against the real server it is proved by two tools.
  `sorello-transcribe --download` fetches this Mac's build into a store
  it is given, as the app would, and transcribes with it; its `--source`
  puts another address in place of the pin's, so a failure can be staged
  against a server on the same Mac. Only that tool can be pointed
  elsewhere: the app has no such setting. `Sorello --self-test
  --download` makes the packaged app download into a temporary store
  with its own pin and then dictate, so it is proved end to end without
  touching the app's own store.
- `SorelloSnapshots` renders each pill state under a camera island, under
  a notch and on a screen with neither, and each screen of the app, to
  PNG. A change to anything visible is reviewed in those images. The
  menu is the system's to draw, so each of its states is written beside
  them as text, row by row, and reviewed there.
- `Sorello --self-test <file.wav>` runs the assembled app's own session
  with a file in place of the microphone and a recorder in place of the
  paste, and prints what would have been inserted. It needs no permission,
  so it proves the packaged app end to end from a clean location.
- `Sorello --snapshots <dir>` renders the menu-bar item, every window and
  every setup step as the app wires them to its stores, and writes the
  menu's rows as text. It also builds setup and the main window as the
  app shows them, without putting them on screen, takes them through
  every step and section, and fails, naming the window, if one does not
  keep its chrome's size and minimum. It writes the rows of the app's own
  menus as text too, since they show only while a window is open.
  `Sorello --no-setup` opens the app without its setup window, so a
  packaged build can be launched and quit without touching a permission.
- The Intel half of a universal build is compiled and linked on every
  release build, but it cannot run on the Apple silicon Macs Sorello is
  built on. What it does differently, the fallback, is proved there with
  `--cpu`. That the app runs on an Intel Mac is checked by hand on one.
- What tests cannot show is checked by hand on a Mac, on the installed
  build: grant, deny and revoke each permission; rebuild and relaunch;
  hold, double tap, toggle, cancel and Paste Again into a native text
  field, a browser field and a terminal; a second dictation begun while
  the first is still being transcribed; a clipboard manager running; the
  built-in microphone and a Bluetooth headset; secure input (a password
  field) during a hold;
  lock and sleep during a recording; the pill on the built-in display, an
  external display and a full-screen Space, and while the system is
  showing something in the camera island; and no network activity during
  any of it once the model is on the Mac. The download itself on a real
  connection: start it, go on through setup while it runs, quit in the
  middle and continue, cancel, and try it with the network off. The Dock
  icon: there while setup or the main window is open and gone when the
  last closes; the last window closed while Sorello is in front and the
  app that was in front before it is still running, and whether that app
  comes forward; another app brought forward and Sorello's window brought
  back from the Dock and with Command-Tab; the microphone's prompt
  answered from setup, with setup in front afterwards; Sorello hidden
  during a dictation, and a dictation begun while it is hidden, the pill
  showing in both.

## 12. Provenance

Sorello was written new. The session, shortcuts, capture, insertion, pill,
windows, storage and build were written from this document. The speech
runtime, dictionary, text rules and permission card were ported from code
written for LocalFlow by the same author; the permission card keeps the MIT
notices of the projects it adapts. The model's licence and attribution ship
in the app's resources.
