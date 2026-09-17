# Goat Voice

Local voice typing for macOS. Hold Right Option, speak, and release to insert the transcript into the focused text field.

Goat Voice runs in the menu bar and transcribes on your Mac with Qwen3-ASR or WhisperKit. A compact indicator shows input volume and provisional text while you speak, adapting to displays with or without a notch. If automatic insertion is unavailable, clipboard recovery keeps the transcript accessible.

Goat Voice is in public beta. Recognition quality, latency, and compatibility across applications still require real-device validation.

## Install

Download the Apple Silicon DMG from [Releases](https://github.com/goat-agent/goat-voice/releases), open it, and drag Goat Voice to Applications.

These builds are ad-hoc signed and are not notarized by Apple. macOS may block first launch until you explicitly allow the downloaded app in System Settings → Privacy & Security. Review the source and download origin before allowing it. Developer ID signing can be added in a future release.

In Goat Voice Settings, grant microphone and Accessibility access, choose a microphone, and download a model:

- Qwen3-ASR 1.7B, 8-bit: approximately 2.47 GB
- Whisper large-v3-turbo: approximately 1.64 GB

Models are downloaded only when requested, with pinned URLs and SHA-256 verification. No release-default model has been selected. Existing settings and models are retained by migrations; macOS permissions may need to be granted again after an ad-hoc update.

## Updates

Use **Check for Updates…** in the menu bar. Sparkle verifies update archives with the public key embedded in the app. Downloads and installation are user initiated; starting dictation cancels update checks and downloads, and installation is not started while a session is active.

The update feed is published only after the release archive is available and its public download checksum has been verified. Sparkle signing verifies the update source; it does not replace Apple notarization. Older development builds without an update feed need a one-time manual installation of the first public release.

## Privacy and delivery

Audio, transcripts, and target context stay local. The app keeps no recording or transcript history. Network access is limited to model downloads and manually requested updates; network work is paused during dictation. No external telemetry service is configured.

Only final text is eligible for insertion. The app checks the focused target, user edits, and clipboard ownership before attempting one paste. It does not retry an uncertain paste automatically.

## Build and test

Building requires Apple Silicon, full Xcode with the Metal toolchain, and Swift 6.3 or later. The app targets macOS 14 or later. CI uses the GitHub `macos-26` runner with Xcode 26.6.

```sh
JOBS=4 bash scripts/build-app.sh
open "build/Goat Voice.app"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test -j 4
python3 -m unittest discover -s Tests -p 'test_*.py'
bash scripts/check-bundle.sh
```

The build script defaults to a release configuration and applies ad-hoc signatures. Set `CONFIGURATION=debug` for a debug build. `DEVELOPER_DIR`, `SCRATCH_PATH`, and `BUILD_DIR` can also be overridden. Model weights are never included in the app or fetched by CI.

The tests use synthetic audio and controlled system interfaces. The bundle check validates signing and a real connection to the embedded transcription service. Neither replaces live microphone, recognition-quality, or application-compatibility testing.

## Structure

| Module | Responsibility |
|---|---|
| `GoatVoiceCore` | Session state, audio bounds, normalization, delivery policies |
| `GoatVoicePlatform` | Audio, input, Accessibility, clipboard, storage, XPC client |
| `GoatVoiceApp` | Menu bar, settings, indicator, application composition |
| `GoatVoiceService` | Local inference and model lifecycle |

Dependencies are pinned in `Package.swift` and `Package.resolved`. Contributor guidance is in [AGENTS.md](AGENTS.md).

## Releasing

`release.json` is the single source for the version, increasing build number, prerelease status, Sparkle public key, repository, and feed URL. The build script writes that configuration into both bundles before signing.

1. Increase the version and build number in `release.json`, review the changes, and merge passing CI into `main`.
2. Push a matching version tag, such as `v0.1.4`. The Release workflow verifies that the tag belongs to `main`, runs tests, builds the app, and checks the embedded service.
3. A separate job signs the exact retained archive, verifies it against the app public key, publishes a GitHub Release, verifies the public download, and finally updates the `updates` branch containing `appcast.xml`.

The `release` GitHub environment holds the `SPARKLE_PRIVATE_KEY` secret. That secret is available only to the signing step, not PR builds or dependency compilation. The key's private seed must be backed up securely and must never be committed. Changing the public key requires a planned Sparkle key transition; do not regenerate it for each release.

Published archives are immutable. To repair a failed feed publication, rerun the failed publish job using the original retained artifact. Do not rebuild and overwrite a published version; issue a higher version/build for changed bytes. Releases are serialized and feed publication rejects rollback. Previous feed items are retained for compatibility with older macOS versions.

For a local development DMG:

```sh
bash scripts/create-dmg.sh
```

## License

Goat Voice is available under the [MIT License](LICENSE). Bundled dependency and tokenizer license texts are in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and included in the app. Downloadable model weights have their own upstream licenses and are not redistributed in Goat Voice releases.
