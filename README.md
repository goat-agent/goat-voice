# Goat Voice

Local voice typing for macOS. Hold Right Option, speak, and release to insert the transcript into the focused text field.

Goat Voice runs in the menu bar and transcribes on your Mac with Qwen3-ASR or WhisperKit. A compact indicator shows input volume and provisional text while you speak, adapting to displays with or without a notch. If automatic insertion is unavailable, clipboard recovery keeps the transcript accessible.

This is a development build. Recognition quality, latency, and compatibility across applications still require real-device validation.

## Requirements

- Apple Silicon Mac running macOS 14 or later
- Full Xcode with its Metal toolchain and Swift 6.2 or later
- Microphone and Accessibility permissions for dictation and text insertion

## Build and run

```sh
JOBS=4 bash scripts/build-app.sh
open "build/Goat Voice.app"
```

The build script defaults to a release configuration and applies ad-hoc signatures for local development. Set `CONFIGURATION=debug` for a debug build. `DEVELOPER_DIR`, `SCRATCH_PATH`, and `BUILD_DIR` can also be overridden.

In Settings, configure the shortcut and microphone, grant the required permissions, and download a model:

- Qwen3-ASR 1.7B, 8-bit: approximately 2.47 GB
- Whisper large-v3-turbo: approximately 1.64 GB

Model downloads are explicit. Artifacts use pinned URLs and SHA-256 verification. No release-default model has been selected.

## Privacy and delivery

Audio, transcripts, and target context stay local. The app keeps no recording or transcript history. Network access is limited to model downloads and manually requested updates; network work is paused during dictation.

Only final text is eligible for insertion. The app checks the focused target, user edits, and clipboard ownership before attempting one paste. It does not retry an uncertain paste automatically.

## Verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test -j 4
python3 -m unittest discover -s Tests -p test_release_evaluation.py
bash scripts/check-bundle.sh
```

The tests use synthetic audio and controlled system interfaces. The bundle check validates signing and a real connection to the embedded transcription service. Neither replaces live microphone, recognition-quality, or application-compatibility testing.

## Structure

| Module | Responsibility |
|---|---|
| `GoatVoiceCore` | Session state, audio bounds, normalization, delivery policies |
| `GoatVoicePlatform` | Audio, input, Accessibility, clipboard, storage, XPC client |
| `GoatVoiceApp` | Menu bar, settings, indicator, application composition |
| `GoatVoiceService` | Local inference and model lifecycle |

Dependencies are pinned in `Package.swift` and `Package.resolved`. Contributor guidance is in [AGENTS.md](AGENTS.md).

## Packaging

```sh
bash scripts/create-dmg.sh
```

This creates `build/Goat Voice-dev.dmg`. Developer ID signing, notarization, and the Sparkle release feed are not configured.
