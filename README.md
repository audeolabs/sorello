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

## Install

Open the DMG, drag Sorello to Applications, and open it from there.

Sorello Nightly installs beside Sorello, with its own settings, speech model and permissions. Its icon has small
orange stars on it, so you can tell the two apart. Quit one before you open the other: both answer the same
shortcuts.

Sorello lives in the menu bar. It shows in the Dock only while one of its windows is open.

## First run

Setup opens and takes you through six steps:

1. **Welcome.**
2. **The speech model.** Download it: it is 138 MB, fetched once from Hugging Face. You can go on with setup while
   it downloads.
3. **The microphone,** so Sorello can hear you. It listens only while you dictate.
4. **Accessibility,** so the shortcut works in every app and Sorello can paste your words. Setup opens System
   Settings with a card: drag Sorello from the card into the list, turn it on, and come back to Sorello.
5. **Your shortcut.** Hold to Talk is the `fn` key unless you choose another.
6. **Try it,** in a test field of setup's own.

You can skip a step with Not Now. Until you finish setup, it opens again each time Sorello starts. After that it
opens again only when the model is not downloaded, Accessibility is off or the microphone was refused, at that
step.

On an Apple silicon Mac, the first time the model loads it is prepared for the Neural Engine, which can take a few
minutes. You can dictate meanwhile: your words are pasted once it is ready.

## Dictating

These use Hold to Talk's shortcut, `fn` unless you chose another.

- **Hold to Talk.** Hold `fn`, speak, and let go. The words are pasted at the cursor.
- **Hands-free.** Tap `fn` twice quickly and speak with nothing held. Tap it once more to stop and paste.
- **Tap to Toggle.** Press once to start and again to stop. It has no shortcut until you give it one.
- **Cancel.** Press Escape to throw away the dictation you are recording. When nothing is recording, Escape
  throws away every dictation that has not been pasted yet, transcribed or not. A paste already under way is
  left alone.
- **Paste Again.** Pastes your last dictation again. It has no shortcut until you give it one.
- **Copy Last Dictation,** in the menu, puts your last dictation on the clipboard.

A recording stops by itself after 15 minutes, and what it heard is pasted. You can start a new dictation while the
last one is still being transcribed. Each is pasted in the order you spoke.

Change the shortcuts in Settings, on the Shortcuts screen. A shortcut is a key with modifiers, such as `⌃⌥Space`,
or modifier keys alone, such as `fn` or the right `⌥`. It can't be Escape, or a key that types on its own. The
same screen says what a double tap of Hold to Talk does: dictate hands-free (the default), start a prompt, or
nothing. To start a prompt, tap Hold to Talk, then hold it as you speak: the text starts with `[dictated]`, so an AI
agent reading it knows it was dictated.

If `fn` opens the emoji picker or changes the input source, open System Settings, Keyboard, and set what the fn
or Globe key does to "Do Nothing". The Shortcuts screen has a button that opens that pane.

### The pill

While you dictate, a small black pill drops down from the top of the screen, below the menu bar or the camera
notch.

- **Listening:** a row of dots that moves with your voice, and the time. In a hands-free or Tap to Toggle
  dictation, click the pill to stop, or its small cancel button to throw the dictation away.
- **Waiting:** a shimmer while the last words are transcribed. "Preparing model" means the model is still
  loading.
- **A message:** for example "Nothing heard", or "Copied. Press ⌘V to paste." when Sorello couldn't paste and left
  the text on the clipboard instead.

### The menu

Click Sorello's icon in the menu bar. The menu shows whether Sorello is ready, with a command that fixes it when it
is not. Below that are your three shortcuts (choose one to change it), Copy Last Dictation, Dictionary, Run Log,
Settings…, Check for Updates… and Quit. The menu never shows what you dictated.

## What happens to the words

Sorello uses a few fixed rules, not a language model. Turn each on or off in Settings, on the General screen.

- **Numbers as digits,** on at first. "It costs five dollars." becomes "It costs $5.", and "Meet at three thirty
  pm." becomes "Meet at 3:30 PM." Small numbers on their own, such as "two", stay as words.
- **Spoken quotes and brackets,** off at first. "He said quote go for it unquote" becomes `He said "go for it"`.
  Open and close paren, bracket, brace and backtick work the same way, and "all caps on … all caps off" writes the
  words between them in capitals.
- **Say "press enter" to send,** off at first. A dictation that ends with "press enter" presses Return after the
  paste: "Send it, press enter" pastes "Send it" and presses Return.
- **Restore the clipboard,** on at first. Sorello pastes through the clipboard and puts back what you had copied a
  second later.

When you dictate into the middle of a sentence, Sorello reads a few characters either side of the cursor so the
words fit: the first word is not capitalised, and a full stop the sentence doesn't need is left out.

### Macros

A macro pastes saved text when you say its phrase. Add one in Settings, on the Macros screen: what you say, and
what to paste. Say the phrase on its own and the saved text is pasted as you saved it, untouched by the rules
above, except that spaces, tabs and line breaks at its ends are left off. Case and punctuation in what you say don't
matter; said inside a longer dictation, the phrase is just words.

### Dictionary

Add names and terms that get misheard in Settings, on the Dictionary screen. Each has a strength: the higher it is,
the harder Sorello pulls toward that spelling. A word can be used everywhere or only in apps you choose. The
dictionary holds up to 1000 words, and can be changed only once the speech model is downloaded.

When you fix a word right after dictating it, Sorello may offer to add it: the pill asks "Add … to your
dictionary?", with Add (or Add to the app and Add Everywhere), Not Now and Don't Suggest. The offer goes away by
itself after 12 seconds. It needs Accessibility, and "Suggest dictionary words" on the General screen turns it
off.

### Run Log

The Run Log keeps your last 20 dictations, with their audio, on this Mac. Open it from the menu. You can play a
dictation, copy it, transcribe it again with today's rules and the dictionary words that apply everywhere
(nothing is pasted), or delete it. If a transcription fails, retry it here. Clear All deletes every dictation and
its audio, and makes Sorello forget the last dictation, so Paste Again and Copy Last Dictation have nothing to
paste. Turning off "Keep a Run Log" on the General screen stops new dictations from being kept; it does not delete
the ones already there, so use Clear All for that.

### Other settings

On the General screen: which microphone to use (the system default unless you choose one), and whether Sorello
opens at login.

## When something is wrong

The menu's first line says what is wrong, and the command under it leads to the fix.

- **Accessibility access needed.** No shortcut works, and nothing can be pasted. Choose Fix…, then
  Open System Settings, and turn Sorello on under Accessibility. This also happens if the permission is turned off
  later.
- **Microphone access needed.** Choose Fix…, then Open System Settings, and turn Sorello on under Microphone.
- **Speech model not downloaded.** Choose Download…, then Download on the General screen. If the download stops,
  the screen says why, and Try Again goes on from where it stopped.
- **Speech model unavailable.** Choose Retry.
- **No speech model for this Mac yet.** There is nothing to download for this Mac at the moment.
- **Shortcuts paused for a password field.** While a password field has the keyboard, the Mac keeps its keys from
  other apps. The shortcuts come back when you leave it.

## Updates

Sorello checks for a newer version once a day while it runs. Choose Check for Updates… in the menu to check now.
When a check Sorello made by itself finds a version, it never interrupts you: the menu's row reads Update
Available… instead, and choosing it shows the new version. Nothing is installed until you say so. The new version
replaces the old one and keeps its settings, speech model and permissions. "Check for updates automatically" on
the General screen turns the daily check off. A release follows releases and a nightly follows nightlies.

## Privacy

Speech is recognised on your Mac. Sorello sends nothing about you, your Mac or what you say, and it has no
analytics or crash reporting. It makes two kinds of network connection:

- **The speech model's download,** from Hugging Face, only when you press Download. The server learns your address
  and which build of the model was asked for. Every file is checked before it is used.
- **The update check,** from GitHub. The server learns your address and Sorello's name and version. An update is
  installed only if its signature matches the key in the app.

Your audio and transcripts are kept only in the Run Log, on this Mac. To fit the words, Sorello reads up to 16
characters either side of the cursor, and to offer a dictionary word it watches what it pasted for up to a minute.
It never reads a password field, and what it reads stays in memory only while it is needed. What you had copied is
held in memory for about a second while Sorello pastes.

## Requirements

- macOS 26 or later.
- A Mac with Apple silicon. Sorello is also built for Intel Macs, where speech is recognised on the processor, more
  slowly, but nobody has run it on an Intel Mac yet.
- A 138 MB download for the speech model.
- The microphone and Accessibility permissions.

## More

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): how to build Sorello and check a build.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the app is put together.
- [ThirdPartyNotices.md](ThirdPartyNotices.md): the work by others that Sorello includes.

## Licence

Sorello's code is under the MIT licence: see [LICENSE](LICENSE). The speech model, kea-b-0.1, is derived from NVIDIA
Parakeet v2 and licensed under CC BY 4.0; its notices ship inside the app and are listed in
[ThirdPartyNotices.md](ThirdPartyNotices.md).
