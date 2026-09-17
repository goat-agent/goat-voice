# Goat Voice

Goat Voice is a native macOS app for local hold-to-talk transcription. Use `GoatVoice` for Swift modules, `goat-voice` for repository names, and `ai.goat.voice` for bundle identifiers. Keep legacy identifiers only where migration requires them.

## Architecture

- Keep `GoatVoiceCore` independent of platform frameworks and inference libraries. Model session transitions and delivery decisions with explicit states and pure policies.
- Put hardware, Accessibility, clipboard, persistence, and XPC adapters in `GoatVoicePlatform`. Inject these boundaries so behavior can be tested without changing the user's system.
- Keep UI and composition in `GoatVoiceApp`; keep inference and model lifecycle in `GoatVoiceService`. Do not perform inference on the main actor.
- Prefer small cohesive types, strong domain types, explicit ownership, and the simplest structure justified by current requirements. Avoid large coordinators, duplicate logic, speculative abstractions, and boolean combinations representing states.

## Swift and concurrency

- Write idiomatic Swift with clear names and narrow access control. Do not add source comments or documentation comments; required toolchain directives are allowed.
- Use actors for isolated mutable state and the main actor for UI. Use locks only for synchronous cross-thread boundaries, with every access to protected state following the same rule.
- Treat `@unchecked Sendable` as an invariant that must be demonstrated and tested, including in test doubles.
- Make asynchronous operation ownership, cancellation, deadlines, and cleanup explicit. Reject stale callbacks using session or operation identity.
- Bound queues, audio buffers, retained text, retries, and concurrent inference. A timeout must not release resources still used by an underlying operation.
- Propagate actionable failures. Do not turn errors into apparent success or silently substitute models, data, or behavior.

## Product invariants

- Keep runtime audio, transcripts, and target text local and volatile. Never include them in logs, telemetry, crash annotations, or test artifacts.
- Only show real inference output. Provisional text stays in the app's indicator; only the final result may enter the delivery path.
- Revalidate target identity, user intent, session validity, and clipboard ownership immediately before writing or posting a paste event.
- Attempt automatic paste at most once. Preserve newer clipboard contents and user edits; an uncertain result must not trigger another paste.
- Keep the interface restrained and accessible. State, actual audio level, and provisional text must work on notched and external displays without stealing focus. Respect reduced motion and system appearance.
- Preserve existing settings and installed models through versioned, idempotent migrations. Do not overwrite newer user data.
- Raise the minimum macOS version only for a concrete product or engineering benefit.

## Changes and validation

- Read the affected implementation and callers before editing. Keep changes focused, preserve unrelated work, and use one writer per module when working in parallel.
- Test behavior and failure boundaries rather than reproducing implementation details. Keep regression assertions meaningful; fix the defect instead of weakening the test.
- Use deterministic fakes for routine tests. Cover cancellation, stale results, ownership changes, and operation ordering when modifying asynchronous flows.
- Synthetic tests do not establish hardware compatibility, recognition accuracy, or latency. Separate measured results from assumptions and report remaining limitations.
- Do not activate the microphone, change system permissions, download model weights, use signing credentials, or publish releases without authorization.

Use full Xcode, including its Metal toolchain. If the system selects Command Line Tools, set `DEVELOPER_DIR` for the command instead of changing the global toolchain. Limit compiler jobs to 2–4.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -j 4
JOBS=4 bash scripts/test.sh
python3 -m unittest discover -s Tests -p test_release_evaluation.py
JOBS=4 bash scripts/build-app.sh
bash scripts/check-bundle.sh
```

Run the checks relevant to the change. Changes to bundling or XPC require the real embedded-service check as well as unit tests. Do not claim release readiness from a successful development build.

## Repository hygiene

- Keep README instructions accurate and self-contained. Do not commit local specifications, investigation diaries, execution logs, agent session records, or generated status reports.
- Keep secrets, `.env` files, credentials, model weights, recordings, caches, and build outputs out of Git.
- Review the staged diff, stage explicit paths, and write focused commits. Do not rewrite shared history or publish changes unless requested.
