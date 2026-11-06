# LocalFlow

LocalFlow is a native macOS menu-bar dictation app. Hold a system-wide hotkey to record, release to transcribe with whisper.cpp, optionally clean the transcript with an OpenAI-compatible LLM, and paste it into the app that currently has focus.

It has no account system, analytics, crash reporting, or application backend. Audio is written only to a per-dictation temporary directory and deleted after insertion or cancellation.

## What works

- Hold-to-talk with the `fn` key by default, or a configured keyboard shortcut.
- Double-tap to continue recording hands-free; tap once more to stop.
- A hard five-minute recording cap. Lower values are configurable; values above 300 seconds are ignored.
- Escape cancels audio capture or terminates an active `whisper-cli` process. Escape is observed passively and still reaches the foreground app.
- A non-activating floating pill shows held, hands-free, and transcription states.
- Pasteboard plus synthetic Command-V insertion. The transcript remains on the clipboard by default.
- Menu-bar on/off toggle, settings reload, permission request, and launch-at-login toggle.
- Local whisper.cpp `small`, `small.en`, `medium`, or `medium.en` models.
- Optional cleanup through any OpenAI-compatible `/chat/completions` endpoint.

## Honest privacy boundary

whisper.cpp transcription is offline. LLM cleanup is offline only when `LLM_BASE_URL` points to a local server. If you point it at a hosted API, the raw transcript leaves the Mac and that provider may require an account. Those facts cannot be reconciled with a literal “no accounts, fully offline” promise.

The default endpoint is local (`http://127.0.0.1:8080/v1`). If no server is running, LocalFlow falls back to the raw whisper.cpp transcript. Set `llm.enabled` to `false` to avoid even the local connection attempt. LocalFlow itself sends no telemetry.

## Requirements

- macOS 13 or later.
- Apple Command Line Tools (`xcode-select --install`).
- CMake to build whisper.cpp. Homebrew users can run `brew install cmake`.
- An OpenAI-compatible local or hosted LLM endpoint for transcript cleanup. This is optional because raw-transcript fallback is on by default.

## Build and install

From this directory:

```bash
./scripts/install-whisper.sh small.en
./scripts/test.sh
./scripts/install-app.sh
open /Applications/LocalFlow.app
```

`small.en` is the sensible English default (about 466 MB). Use `medium.en` for better accuracy at substantially higher memory, disk, and latency cost. Multilingual dictation should use `small` or `medium` and set `whisperLanguage` appropriately (or to `auto`). The model and CLI formats follow the official [whisper.cpp quick start](https://github.com/ggml-org/whisper.cpp#quick-start).

The build is ad-hoc signed. Rebuilding or moving the app can cause macOS to ask for permissions again. A stable Developer ID signature is needed for polished distribution to other Macs.

## Required macOS permissions

On first launch, approve the prompts. Then verify all three entries under Apple menu → System Settings → Privacy & Security:

1. **Microphone → LocalFlow: On** — records dictation audio. Apple documents this panel in [Control access to the microphone on Mac](https://support.apple.com/guide/mac-help/mchla1b1e1fe/mac).
2. **Accessibility → LocalFlow: On** — installs the suppressing global hotkey tap and synthesizes Command-V. Apple documents this panel in [Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/mh43185/mac).
3. **Input Monitoring → LocalFlow: On** — observes Escape without consuming it. Apple documents this panel in [Control access to input monitoring on Mac](https://support.apple.com/guide/mac-help/mchl4cedafb6/mac).

Quit and reopen LocalFlow after changing Accessibility or Input Monitoring. If LocalFlow is absent from a list, use the add button in that panel and choose `/Applications/LocalFlow.app`. The menu-bar item’s **Request Permissions** action repeats the system permission requests it can trigger programmatically.

LocalFlow does not need Full Disk Access, Screen Recording, Speech Recognition, or Automation permission.

## Configure the LLM

On first launch LocalFlow creates:

```text
~/Library/Application Support/LocalFlow/.env
```

The menu-bar item can open it. For a local OpenAI-compatible server:

```dotenv
LLM_API_KEY=
LLM_BASE_URL=http://127.0.0.1:8080/v1
LLM_MODEL=local-model
```

For a hosted compatible API, change the base URL and model and put its key in `LLM_API_KEY`. Do not put the key in `settings.json`. `.env` is read for every dictation, so key changes do not require a restart. LocalFlow forces both configuration files to owner-only (`0600`) permissions on launch.

The cleanup prompt is deliberately short: remove filler and abandoned false starts, repair punctuation, preserve meaning, and match casing to the dictated style. The model is instructed to return only edited text.

## Configure the hotkey and behavior

On first launch LocalFlow also creates:

```text
~/Library/Application Support/LocalFlow/settings.json
```

The defaults are equivalent to:

```json
{
  "clipboardRestoreDelayMilliseconds": 400,
  "doubleTapWindowMilliseconds": 350,
  "enabled": true,
  "hotkey": {
    "key": "fn",
    "modifiers": []
  },
  "llm": {
    "apiKeyEnvironmentVariable": "LLM_API_KEY",
    "baseURL": "http://127.0.0.1:8080/v1",
    "enabled": true,
    "fallbackToRawTranscript": true,
    "model": "local-model"
  },
  "maxRecordingSeconds": 300,
  "restorePreviousClipboard": false,
  "whisperExecutable": "~/Library/Application Support/LocalFlow/whisper.cpp/build/bin/whisper-cli",
  "whisperLanguage": "en",
  "whisperModel": "~/Library/Application Support/LocalFlow/whisper.cpp/models/ggml-small.en.bin"
}
```

After editing the file, choose **Reload Settings** from the menu-bar item.

For a chord instead of `fn`, for example Control-Option-Space:

```json
"hotkey": {
  "key": "space",
  "modifiers": ["control", "option"]
}
```

Supported modifier names are `command`, `control`, `option`, and `shift`. Supported keys are letters, digits, `space`, `tab`, `return`, `backspace`, arrow keys, `f13` through `f20`, and the punctuation keys shown on a US keyboard. The unused extended function keys can be used without modifiers; other non-`fn` hotkeys require at least one modifier so a bad configuration cannot swallow ordinary typing system-wide. A configured chord is swallowed so it does not type into the foreground app. Escape is reserved for cancellation and is never swallowed.

For a programmable keyboard key such as M1, map that physical key to F13 in the keyboard firmware, then use:

```json
"hotkey": {
  "key": "f13",
  "modifiers": []
}
```

Mapping to a real extended function key preserves key-down and key-up events, so hold-to-talk works. A recorded macro usually emits an immediate press and release and is therefore the wrong mechanism.

Set `restorePreviousClipboard` to `true` to restore all prior pasteboard items after Command-V. Restoration is delayed by `clipboardRestoreDelayMilliseconds` so the foreground app has time to consume the paste. Clipboard managers may still observe the temporary transcript.

## Interaction details

- Hold longer than the double-tap window: release stops immediately.
- Quick single tap: LocalFlow waits for the remainder of the 350 ms window, then stops.
- Quick double-tap: the same uninterrupted recording becomes hands-free.
- One more hotkey press: stops hands-free recording.
- Escape: cancels at any point and deletes the temporary recording.

The short single-tap delay is necessary to distinguish a single tap from a double-tap without cutting the audio between them.

## Development

```bash
swift build
./scripts/test.sh
./scripts/build-app.sh
```

The self-test covers hold/double-tap/third-tap/cancel/max-duration state transitions, `.env` parsing, endpoint construction, and the five-minute hard cap. This checkout’s standalone Command Line Tools omit both XCTest and Swift Testing, so the suite is a small framework-free executable instead of `swift test`.

There is no automated end-to-end test for microphone permission, global event taps, or paste injection; macOS only exercises those correctly from a signed `.app` in a logged-in GUI session. Test those manually in TextEdit before relying on the app system-wide.
