# Pardon for meetings

A Mac menu-bar app from Pardon for people learning English, French, German or Spanish. It records your meetings, transcribes them on your Mac, and afterward gives you notes on how you spoke the meeting's language: what went well, the mistakes worth fixing (with the better sentence and a short reason), patterns that keep coming back, and one thing to practice. The reasons are written in your native language; the corrections stay in the language you are learning.

Audio and transcripts never leave your Mac. If you turn on notes, only your own lines (never the other people in the meeting) are sent to Pardon, on your Pardon account, to write them.

Built on [Quill](https://github.com/humanitas-labs/quill) by Humanitas Labs (MIT).

## 1. Install

```sh
./scripts/build-macos
sudo ./scripts/install-macos
pardon install --launch-at-login   # optional
```

Requires macOS 15+. Apple Silicon is recommended for transcription speed.

## 2. Usage

1. Open Pardon. The welcome window asks you to **Sign in with Pardon** (your browser opens; sign in there and choose Continue to the app), then fills in your native language and your languages and levels from your Pardon account, asks for the microphone and your Mac's sound, and downloads the speech model.
2. Everything can be changed later from the asterisk in the menu bar: **This meeting is in**, **Your level**, **Your native language**, **Notes after meetings**, **Set up again...** and **Sign out**.
3. Choose **Start recording** when a meeting starts. First use asks for microphone and system audio permissions.
4. Choose **Stop recording** when it ends. Transcription and notes run automatically, and a notification tells you when they are ready. Meetings set to your native language get a transcript but no notes.
5. Choose **Open latest notes**. Everything lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`: `transcript.md`, `notes.md`, next to the audio.

To redo the notes for a meeting: `pardon notes ~/Recordings/<folder>`.

See the [macOS documentation](macos/README.md) for configuration, the CLI, and troubleshooting.

## 3. Platforms

| Platform | Status | Documentation |
|---|---|---|
| macOS 15+ | Working | [macOS](macos/README.md) |
| Windows 11 | Capture probe planned | [Windows](windows/README.md) |
| Linux | Capture probe proposed | [Linux](linux/README.md) |

Each platform is a native, independent implementation. They share the session layout, transcript format, and test fixtures, not source code. See [docs/architecture.md](docs/architecture.md).

## 4. License

[MIT](LICENSE), from Quill by Humanitas Labs.
