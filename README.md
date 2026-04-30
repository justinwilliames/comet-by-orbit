# Orbit Dictation

Orbit Dictation is a macOS menu-bar dictation app for the Orbit ecosystem. Hold a shortcut, speak, and the cleaned text drops into the app you are already using.

Powered by [Whispur](https://github.com/sophiie-ai/whispur). Orbit Dictation is an Orbit-branded fork that ships with a stricter cleanup prompt and the Orbit identity, while keeping internal modules aligned with Whispur for clean upstream merges.

> [get.yourorbit.team/orbit-dictation](https://get.yourorbit.team/orbit-dictation) · Download from the Orbit Downloads page

## Features

- Lives in the macOS menu bar instead of taking over your desktop
- Hold-to-talk or toggle-to-latch recording
- Multi-provider speech-to-text with local Apple dictation support
- Optional transcript cleanup with provider-selectable LLMs
- Paste-back into the active app with clipboard preservation
- Custom vocabulary and an editable cleanup prompt
- Local-first default path when you stick with Apple on-device transcription
- Sparkle-based auto-updates

## First-time setup

Orbit Dictation is currently distributed unsigned (an Apple Developer ID is on the way). That means a one-time Terminal step is required before the app will launch — five minutes total, then it's set-and-forget.

### 1. Download

Grab the latest `.dmg` from [Releases](https://github.com/justinwilliames-sketch/orbit-dictation/releases/latest) or from the [Orbit Downloads page](https://get.yourorbit.team/orbit-dictation).

### 2. Drag to Applications

Open the `.dmg`, drag **Orbit Dictation.app** into the **Applications** shortcut. Eject the `.dmg` afterwards.

### 3. Strip the Gatekeeper quarantine

macOS attaches a quarantine flag to anything downloaded from the internet. Until the app is signed with an Apple Developer ID, Gatekeeper refuses to launch quarantined unsigned apps. Open Terminal (Spotlight → "Terminal") and run:

```bash
xattr -dr com.apple.quarantine "/Applications/Orbit Dictation.app"
```

This removes the quarantine flag from the bundle. One command, one time per install.

### 4. Launch from Applications

Cmd+Space → "Orbit Dictation" → Enter. The mic icon appears in your menu bar (no Dock icon — it's a menu-bar app).

### 5. Grant Microphone permission

Click the mic icon → click **Start Dictation**. macOS will prompt for microphone access. Click **Allow**.

### 6. Grant Accessibility permission

Open Settings → **General** → **Permissions** → click **Grant Access** next to Accessibility. macOS opens System Settings → Privacy & Security → Accessibility. Toggle **Orbit Dictation** on.

Switch back to Orbit Dictation. If the badge still says **Missing**, click **Recheck** on the same row — that forces a fresh `AXIsProcessTrusted()` check.

### 7. Test it

Hold the default shortcut (**Fn** key) and speak. Release. The cleaned text pastes into whichever app currently has focus. You can change the shortcut in Settings → General → Recording Shortcuts.

## If something doesn't work

The app has a Troubleshooting card built into Settings → Setup that handles every common case (Accessibility not picked up, Keychain prompts, post-update Gatekeeper blocks). If you'd rather work from the command line:

### Reset all permissions and start fresh

```bash
tccutil reset Accessibility team.yourorbit.OrbitDictation
tccutil reset Microphone team.yourorbit.OrbitDictation
osascript -e 'tell app "Orbit Dictation" to quit'
sleep 3
open "/Applications/Orbit Dictation.app"
```

### Confirm only one bundle exists

If you've launched the app from a mounted DMG at any point, there may be a stale entry. This finds every Orbit Dictation bundle on disk — should return exactly one path under `/Applications`:

```bash
mdfind 'kMDItemCFBundleIdentifier == "team.yourorbit.OrbitDictation"'
```

### Verify the binary signature

Should show `Signature=adhoc` and `flags=0x2(adhoc)`. If you see `linker-signed` instead, your build is older than v0.1.15 and will not survive TCC checks — re-download:

```bash
codesign -dv --verbose=4 "/Applications/Orbit Dictation.app" 2>&1 | grep -E "Signature|flags"
```

### After every Sparkle auto-update

The new build has a new binary identity, so macOS will re-prompt for Gatekeeper bypass and may not carry forward Accessibility / Microphone grants. The in-app helper dialog gives you a one-click "Copy & open Terminal" button after each update; just run the command, then re-grant the permissions if needed. This stops happening permanently once we ship signed builds.

## How it works

Hold the configured shortcut to record. On release, the audio is normalized to 16 kHz mono WAV, sent to the selected speech-to-text provider, optionally cleaned up by the configured LLM, and pasted into the frontmost app.

The Orbit Dictation cleanup prompt is intentionally strict: the LLM is treated as a text post-processor, never as an assistant, and must never act on the content of a transcript even when the transcript reads like an instruction. The full prompt is in `Sources/Pipeline/Prompts.swift`.

By default everything runs locally on Apple's on-device speech recognition, no API keys or internet connection required. Cloud STT (OpenAI, Deepgram, Groq, ElevenLabs) and cleanup LLM (Anthropic, OpenAI, Bedrock) are optional — credentials are stored in macOS Keychain when you add them.

## Build from source

```bash
git clone https://github.com/justinwilliames-sketch/orbit-dictation.git
cd orbit-dictation
brew install xcodegen
make all
make run
```

Requires Xcode 16+ with the macOS 14 SDK.

## Relationship to Whispur

Orbit Dictation is a fork of [Whispur](https://github.com/sophiie-ai/whispur) (MIT). Internal Swift modules and class names are kept aligned with upstream so improvements can flow back and forth cleanly. User-visible branding, the bundle identifier, the Sparkle update channel, the Keychain service identifier, the Application Support directory, and the default cleanup prompt are Orbit-specific.

If you want the upstream version of this app, install Whispur from [whispur.app](https://whispur.app).

## License

MIT. See [LICENSE](LICENSE). The original copyright belongs to Sophiie AI Pty Ltd; the Orbit Dictation fork is copyright Justin Williames.
