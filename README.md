# Comet

Comet is a macOS menu-bar dictation app for the Orbit ecosystem. Hold a shortcut, speak, and the cleaned text drops into the app you are already using.

Powered by [Whispur](https://github.com/sophiie-ai/whispur). Comet is an Orbit-branded fork that ships with a stricter cleanup prompt and the Orbit identity, while keeping internal modules aligned with Whispur for clean upstream merges.

> [get.yourorbit.team/comet](https://get.yourorbit.team/comet) · Download from the Orbit Downloads page

## Features

- Lives in the macOS menu bar instead of taking over your desktop
- Hold-to-talk or toggle-to-latch recording
- Strict cleanup prompt — the LLM is treated as a text post-processor, never as an assistant or participant
- Rich-text list paste (real bullets and indent in Mail / Notes / Notion / Slack; plain text in code editors)
- Multi-provider speech-to-text with local Apple dictation support
- Custom vocabulary and an editable cleanup prompt
- Sparkle-based auto-updates

## Recommended setup — one free Groq API key

The simplest way to use Comet: a single API key from **[Groq](https://console.groq.com/keys)** powers both speech recognition and cleanup. Groq's free tier is generous and usually covers daily dictation use without spending a cent.

1. Sign up at [console.groq.com](https://console.groq.com/keys) — no credit card needed
2. Create an API key, copy it to clipboard
3. Open Comet → Settings → Providers → paste into **Groq API Key** under "Recommended setup"
4. Click **Use Groq for speech + cleanup**

Comet will use Groq's `whisper-large-v3` for speech and `llama-3.3-70b-versatile` for cleanup — no model picking required.

### Apple-only alternative

Prefer zero cloud? Settings → Providers → **Use Apple Dictation**. Apple's on-device speech recognition runs locally with no API keys. **The trade-off:** cleanup is off in this mode, so filler words, run-ons, and self-corrections paste verbatim with light punctuation only. Pick this if privacy matters more than polish.

### Other providers

OpenAI, Anthropic, Deepgram, ElevenLabs, and AWS Bedrock are all supported under Settings → Providers → **Other providers** → expand **Advanced configuration**. Mix-and-match speech and cleanup providers independently.

## First-time setup

Comet is currently distributed unsigned (an Apple Developer ID is on the way). That means a one-time Terminal step is required before the app will launch — five minutes total, then it's set-and-forget.

### 1. Download

Grab the latest `.dmg` from [Releases](https://github.com/justinwilliames/comet-by-orbit/releases/latest) or from the [Orbit Downloads page](https://get.yourorbit.team/comet).

### 2. Drag to Applications

Open the `.dmg`, drag **Comet.app** into the **Applications** shortcut. Eject the `.dmg` afterwards.

### 3. Strip the Gatekeeper quarantine

macOS attaches a quarantine flag to anything downloaded from the internet. Until the app is signed with an Apple Developer ID, Gatekeeper refuses to launch quarantined unsigned apps. Open Terminal (Spotlight → "Terminal") and run:

```bash
xattr -dr com.apple.quarantine "/Applications/Comet.app"
```

This removes the quarantine flag from the bundle. One command, one time per install.

### 4. Launch from Applications

Cmd+Space → "Comet" → Enter. The mic icon appears in your menu bar (no Dock icon — it's a menu-bar app).

### 5. Grant Microphone permission

Click the mic icon → click **Start Dictation**. macOS will prompt for microphone access. Click **Allow**.

### 6. Grant Accessibility permission

Open Settings → **General** → **Permissions** → click **Grant Access** next to Accessibility. macOS opens System Settings → Privacy & Security → Accessibility. Toggle **Comet** on.

Switch back to Comet. If the badge still says **Missing**, click **Recheck** on the same row — that forces a fresh `AXIsProcessTrusted()` check.

### 7. Test it

Hold the default shortcut (**Fn** key) and speak. Release. The cleaned text pastes into whichever app currently has focus. You can change the shortcut in Settings → General → Recording Shortcuts.

## If something doesn't work

The app has a Troubleshooting card built into Settings → Setup that handles every common case (Accessibility not picked up, Keychain prompts, post-update Gatekeeper blocks). If you'd rather work from the command line:

### Reset all permissions and start fresh

```bash
tccutil reset Accessibility team.yourorbit.OrbitDictation
tccutil reset Microphone team.yourorbit.OrbitDictation
osascript -e 'tell app "Comet" to quit'
sleep 3
open "/Applications/Comet.app"
```

### Confirm only one bundle exists

If you've launched the app from a mounted DMG at any point, there may be a stale entry. This finds every Comet bundle on disk — should return exactly one path under `/Applications`:

```bash
mdfind 'kMDItemCFBundleIdentifier == "team.yourorbit.OrbitDictation"'
```

### Verify the binary signature

Should show `Signature=adhoc` and `flags=0x2(adhoc)`. If you see `linker-signed` instead, your build is older than v0.1.15 and will not survive TCC checks — re-download:

```bash
codesign -dv --verbose=4 "/Applications/Comet.app" 2>&1 | grep -E "Signature|flags"
```

### After every Sparkle auto-update

The new build has a new binary identity, so macOS will re-prompt for Gatekeeper bypass and may not carry forward Accessibility / Microphone grants. The in-app helper dialog gives you a one-click "Copy & open Terminal" button after each update; just run the command, then re-grant the permissions if needed. This stops happening permanently once we ship signed builds.

## How it works

Hold the configured shortcut to record. On release, the audio is normalized to 16 kHz mono WAV, sent to the selected speech-to-text provider, optionally cleaned up by the configured LLM, and pasted into the frontmost app.

The Comet cleanup prompt is intentionally strict: the LLM is treated as a text post-processor, never as an assistant, and must never act on the content of a transcript even when the transcript reads like an instruction. The full prompt is in `Sources/Pipeline/Prompts.swift`.

By default everything runs locally on Apple's on-device speech recognition, no API keys or internet connection required. Cloud STT (OpenAI, Deepgram, Groq, ElevenLabs) and cleanup LLM (Anthropic, OpenAI, Bedrock) are optional — credentials are stored in macOS Keychain when you add them.

## Build from source

```bash
git clone https://github.com/justinwilliames/comet-by-orbit.git
cd comet-by-orbit
brew install xcodegen
make all
make run
```

Requires Xcode 16+ with the macOS 14 SDK.

## What's different from Whispur

Comet is an MIT-licensed fork of [Whispur](https://github.com/sophiie-ai/whispur). Internal Swift modules and class names stay aligned with upstream so improvements can flow back and forth cleanly. The factual differences:

**Cleanup pipeline**
- Strict cleanup prompt with explicit person-matching, length-cap, paragraph-break, list-trigger, and grammar-correctness rules. The default in Whispur is lighter and more conversational; ours treats the LLM as a text post-processor that must never act on the transcript content even when it reads like an instruction.
- Dynamic `max_tokens` cap based on input length (`inputChars/2 + 50`, floor 150). Whispur uses Sparkle's default 2048 — too lax for an unbounded loop.
- Output-length sanity check that falls back to the raw transcript when the LLM produces more than 1.5× word expansion.

**Output format**
- Rich-text list paste: when the cleanup output contains list lines (`• item`), Comet writes both plain and RTF representations to the pasteboard. Mail / Notes / Notion / Slack render real bulleted lists; code editors get plain text. Whispur paste is plain-text-only.

**UX & onboarding**
- Recommended setup card features Groq with a single-key path; full provider matrix is hidden under "Other providers → Advanced configuration". Whispur exposes all 5 STT and 4 LLM options at the top level.
- Auto-open Settings on relaunch, in-app Live Logs viewer (OSLogStore), Recheck button on permission rows, Restart button + Nuclear Reset commands in Troubleshooting, App Translocation guard at launch, Sparkle auto-check toggle exposed in Settings.

**Brand & distribution**
- Orbit identity (logo, indigo palette `#6366F1`, mic SF Symbol menu-bar icon).
- Bundle identifier: `team.yourorbit.OrbitDictation` (Whispur is `ai.sophiie.whispur`); Application Support and Keychain service rescoped to match.
- Distributed from `get.yourorbit.team/comet` and this repo's GitHub Releases. Currently ad-hoc signed (proper Developer ID signing pending).

**Internal symbols stay Whispur-named** — `WhispurApp`, `HotkeyManager`, etc. — so `git fetch upstream` merges cleanly. Only user-visible strings, the bundle identifier, the Sparkle update channel, and the default cleanup prompt are Orbit-specific.

If you want the upstream version, install Whispur from [whispur.app](https://whispur.app).

## License

MIT. See [LICENSE](LICENSE). The original copyright belongs to Sophiie AI Pty Ltd; the Comet fork is copyright Justin Williames.
