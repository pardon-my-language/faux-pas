# Darn for meetings

Darn is Pardon's English companion. This Mac menu-bar app records your meetings, transcribes them on your Mac, and afterward gives you Darn's notes on how your spoken English went: what went well, the mistakes worth fixing (with the better sentence and a short reason), patterns that keep coming back, and one thing to practice.

Audio and transcripts never leave your Mac. If you turn on Darn's feedback, only your own lines (never the other people in the meeting) are sent to Claude to write the notes.

Built on [Quill](https://github.com/humanitas-labs/quill) by Humanitas Labs (MIT).

## 1. Install

```sh
./scripts/build-macos
sudo ./scripts/install-macos
darn install --launch-at-login   # optional
```

Requires macOS 15+. Apple Silicon is recommended for transcription speed.

## 2. Usage

1. Click the pebble in the menu bar. Set **Your English level** and **Your native language**, and turn on **Darn's feedback after meetings**.
2. Add your Claude API key to `~/.config/darn/config.json`: `{ "darn": { "api_key": "sk-ant-..." } }`.
3. Choose **Start recording** when a meeting starts. First use asks for microphone and system audio permissions.
4. Choose **Stop recording** when it ends. Transcription and Darn's notes run automatically, and a notification tells you when they are ready.
5. Choose **Open latest notes**. Everything lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`: `transcript.md`, `darn.md`, next to the audio.

To redo the notes for a meeting: `darn notes ~/Recordings/<folder>`.

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
