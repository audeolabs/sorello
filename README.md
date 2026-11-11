<p align="center"><img src="docs/images/icon.png" width="128" alt="Sorello"></p>

<h1 align="center">Sorello</h1>

- [Sorello](https://github.com/audeolabs/sorello/releases/latest/download/Sorello.dmg), the latest release. There is
  none yet, so get the nightly for now.
- [Sorello Nightly](https://github.com/audeolabs/sorello/releases/download/nightly/Sorello-Nightly.dmg), built each
  night that the code has changed.

Sorello is an English dictation app for Mac that runs entirely on device. Hold a key, speak, and let go: your words
are pasted where the cursor is. It is powered by the Kea family of English speech models by
[Audeo Labs](https://huggingface.co/audeolabs). [Using Sorello](docs/USING.md) covers setup, shortcuts and settings,
and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) how to build it.

## Requirements

- macOS 26 or later.
- A Mac with Apple silicon (M series).
- The microphone and Accessibility permissions.

## Privacy

Speech is recognised on your Mac, and nothing you say leaves it. Sorello connects to the network for two things only:
the one-time download of the speech model (138 MB, from Hugging Face), and checking for and downloading updates
(from GitHub). Neither sends anything about you. There are no analytics and no crash reporting.

## License

Sorello's code is under the [MIT License](LICENSE). The speech model, kea-b-0.1, is under CC BY 4.0. Its notices,
and the other work Sorello includes, are in [ThirdPartyNotices.md](ThirdPartyNotices.md).
