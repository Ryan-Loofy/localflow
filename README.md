# LocalFlow

LocalFlow is a macOS menu-bar dictation app. Tap a key, talk, tap again (or press Enter), and the text is pasted into whatever app you are typing in, cleaned up: filler words and false starts removed, punctuation fixed, code names in `backticks`, long dictation split into paragraphs.

Everything runs on your Mac. Speech is transcribed by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and cleaned up by a small local model in [Ollama](https://ollama.com). No account, no cloud service, no telemetry. Audio is deleted after each dictation.

Typical speed from your last tap to pasted text: about 0.3 seconds for a short sentence, under 1 second for a paragraph.

## Requirements

- An Apple Silicon Mac (M1 or later), macOS 13 or later.
- 16 GB of memory recommended. It runs on 8 GB, but slowly.
- About 3 GB of free disk space.

## Install

Open Terminal, go to the folder you downloaded or cloned, and run:

```bash
./scripts/setup.sh
```

To use **Caps Lock** as the dictation key instead of fn (recommended on keyboards whose fn key macOS never sees, such as many Keychron and Logitech keyboards), run this instead:

```bash
./scripts/setup.sh --caps-lock
```

The script installs anything missing (Apple's command line tools, Homebrew, cmake, Ollama), builds whisper.cpp, downloads the speech model (about 470 MB) and the cleanup model (about 2 GB), installs LocalFlow into Applications and starts its two background services. It takes about 10 minutes the first time and is safe to run again.

If it stops to install Apple's command line tools, finish that install and run the same command again.

### Allow LocalFlow in System Settings

macOS requires you to switch these on by hand. The setup script opens the right page.

1. **Microphone**: allow the prompt when it appears.
2. **Accessibility**: Apple menu > System Settings > Privacy & Security > Accessibility, switch LocalFlow on. If it is missing, click + and choose `/Applications/LocalFlow.app`.
3. **Input Monitoring**: same place, switch LocalFlow on.

LocalFlow starts listening a few seconds after Accessibility is on. If you use fn as the key, also set System Settings > Keyboard > "Press 🌐 key to" to **Do Nothing**, or fn will open the emoji picker too.

## Using it

- **Tap** the key once to start, talk, then **tap again or press Enter** to stop. The Enter press is not sent to your app, so it never submits a half-written message.
- **Hold** the key for push-to-talk: recording stops when you let go.
- **Escape** cancels and throws the recording away.
- A small pill shows while it is listening and while it is working.

## If it stops working

- **Nothing happens when you press the key.** Another app may have turned on macOS "secure input", which hides every key press from LocalFlow. Docker Desktop's window and password fields are common causes: close them. To see which app holds it: `ioreg -l -w 0 | grep SecureInput`.
- **It worked, then stopped after an update or rebuild.** Builds you make yourself are signed ad hoc, so macOS forgets the Accessibility permission each time. Remove LocalFlow from Accessibility with the minus button and add it back.
- **Text comes out uncleaned.** The cleanup service is not running. Run `./scripts/install-services.sh` again.
- **Check what happened.** `~/Library/Logs/LocalFlow/localflow.log` records start-up, permission state and errors (never what you said), and `timing.log` records how long each step took.

## Settings

Settings live in `~/Library/Application Support/LocalFlow/settings.json`. After editing, choose **Reload Settings** from the menu-bar icon.

- `hotkey`: `{"key": "fn", "modifiers": []}` by default. Keys `f13` to `f20` work alone; other keys need at least one modifier (`command`, `control`, `option`, `shift`), for example `{"key": "space", "modifiers": ["control", "option"]}`.
- `tapToToggle`: `true` (tap on, tap off). `false` uses hold-to-talk with double-tap for hands-free.
- `skipCleanupWhenClean`: `true` skips the cleanup model for short dictation that is already clean, which saves about half a second.
- `llm`: the cleanup model. Any OpenAI-compatible endpoint works; `.env` in the same folder overrides `baseURL` and `model` and holds an API key if one is needed. A hosted model formats better but sends your words off the Mac.
- `restorePreviousClipboard`: `false` by default, so the dictated text stays on the clipboard.

## How it works

LocalFlow listens for the hotkey, records the microphone, sends the audio to the local whisper server (`127.0.0.1:8178`), sends the transcript to Ollama (`127.0.0.1:11434`) for cleanup when it needs it, then pastes with Command-V. Both models are woken the moment you start talking, so they are ready when you stop. The services run as login items (`~/Library/LaunchAgents/com.localflow.*.plist`) and keep their models loaded.

To uninstall: quit LocalFlow, delete `/Applications/LocalFlow.app`, run `launchctl bootout gui/$(id -u)/com.localflow.whisper` and the same for `com.localflow.ollama` and `com.localflow.capslock-f13`, then delete those plist files and `~/Library/Application Support/LocalFlow`.

## Development

```bash
./scripts/test.sh        # self-tests
./scripts/install-app.sh # build, sign and install into /Applications
```

`build-app.sh` signs with a local certificate named "LocalFlow Local Signing" when one is in your keychain, which keeps permissions across rebuilds; otherwise it signs ad hoc. The self-tests cover the state machine, settings, cleanup decisions and audio conversion. Microphone, global hotkeys and pasting can only be tested by hand in a signed app.
