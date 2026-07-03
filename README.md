<div align="center">

<img src="assets/readme/comet-header.png" alt="Comet — hold, speak, it's already typed" width="640" />

<p align="center">
  <a href="https://github.com/justinwilliames/comet-by-orbit/releases/latest"><img src="https://img.shields.io/github/v/release/justinwilliames/comet-by-orbit?include_prereleases&label=latest&color=6366F1" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/license-MIT-6366F1" alt="License MIT" />
  <img src="https://img.shields.io/badge/macOS-14%2B-6366F1" alt="macOS 14+" />
</p>

</div>

**Comet is a macOS menu-bar dictation app.** Hold a shortcut, speak, and the cleaned text drops into the app you are already using. Or go fully hands-free: arm a wake word and dictate — then run commands by voice, including a set for driving Claude Code without touching the keyboard.

> [get.yourorbit.team/comet](https://get.yourorbit.team/comet) · Download from the Orbit Downloads page

## Star History

If Comet saves you keystrokes, a ⭐ helps other people find it.

<a href="https://www.star-history.com/?repos=justinwilliames%2Fcomet-by-orbit%2Cjustinwilliames%2Fpulsar-by-orbit%2Cjustinwilliames%2Forbit-for-claude%2Cjustinwilliames%2Forion-by-orbit&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=justinwilliames/comet-by-orbit%2Cjustinwilliames/pulsar-by-orbit%2Cjustinwilliames/orbit-for-claude%2Cjustinwilliames/orion-by-orbit&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=justinwilliames/comet-by-orbit%2Cjustinwilliames/pulsar-by-orbit%2Cjustinwilliames/orbit-for-claude%2Cjustinwilliames/orion-by-orbit&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=justinwilliames/comet-by-orbit%2Cjustinwilliames/pulsar-by-orbit%2Cjustinwilliames/orbit-for-claude%2Cjustinwilliames/orion-by-orbit&type=date&legend=top-left" />
 </picture>
</a>

## Features

- Lives in the macOS menu bar instead of taking over your desktop
- Hold-to-talk or toggle-to-latch recording
- Hands-free voice control — arm a wake word and dictate, then run keystroke commands entirely by voice, including a command set for driving Claude Code
- Strict cleanup prompt — the LLM is treated as a text post-processor, never as an assistant or participant
- Rich-text list paste (real bullets and indent in Mail / Notes / Notion / Slack; plain text in code editors)
- Multi-provider speech-to-text with local Apple dictation support
- Cleanup via a cloud LLM or a local Claude Code / Codex CLI — no API key required for the CLI path
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

### Local CLI cleanup — no API key

For cleanup, Comet can drive an AI CLI you already have installed instead of a cloud API. Pick **Claude Code CLI** or **Codex CLI** under Settings → Providers and Comet runs it as a subprocess using your existing CLI login — no key to paste, nothing stored. Run `claude` (or `codex`) once in Terminal to sign in first. This covers cleanup only; speech recognition still uses one of the providers above (or Apple on-device).

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

## Voice control (hands-free)

Comet can be driven entirely by voice — no shortcut held, no keyboard touched. Spoken commands are recognized by your own speech provider (a Whisper provider like Groq gives the best accuracy; Apple on-device works too), so there's nothing extra to install.

### Turn it on

1. Settings → **General** → **Wake Word** → toggle **Enable wake word**.
2. Open the menu bar icon → click **Listen for wake word** to arm it. The menu reads *Listening — say "Comet start"…* once armed.
3. Keystroke commands inject into whichever app is focused, so keep **Accessibility** granted (the same permission dictation uses).

### Commands

Every command starts with the wake word **"Comet"** (say "Dictation" instead if you prefer):

- **Dictation** — "Comet start dictation" to begin, "Comet stop dictation" to end. Fully hands-free, no shortcut.
- **Keystrokes (while idle)** — "Comet send", "Comet new line", "Comet select all", "Comet copy", "Comet undo", "Comet delete line", and more.
- **Claude Code control** — answer a permission prompt with "Comet one / two / three", "Comet interrupt" to stop it mid-response, "Comet mode" to cycle modes, "Comet up / down" to navigate, "Comet clear" to clear the input line.

The full, always-current list lives in Settings → **Voice Commands**, read straight from the command table so it never drifts from what the recognizer actually matches. "Comet undo that" reverses any command that misfires.

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

By default everything runs locally on Apple's on-device speech recognition, no API keys or internet connection required. Cloud STT (OpenAI, Deepgram, Groq, ElevenLabs) and cleanup (Anthropic, OpenAI, Groq, Bedrock, or a local Claude Code / Codex CLI) are optional — credentials are stored in macOS Keychain when you add them.

Voice commands work the same way: while the wake word is armed, Comet captures short spoken snippets, transcribes them through the selected speech provider, and matches the result against the command table before injecting the corresponding keystroke into the frontmost app.

## Build from source

```bash
git clone https://github.com/justinwilliames/comet-by-orbit.git
cd comet-by-orbit
brew install xcodegen
make all
make run
```

Requires Xcode 16+ with the macOS 14 SDK.

<details>
<summary><b>What's different from Whispur</b> (for contributors)</summary>

Comet is an MIT-licensed fork of [Whispur](https://github.com/sophiie-ai/whispur). Behaviour-level source stays close to upstream so improvements can flow back and forth, though the Xcode target, module, and app entry point are now `Comet`-named. The factual differences:

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

**Xcode project & internal symbols are Comet-named** — `Comet.xcodeproj`, target/module `Comet`, `CometApp`, `CometTests`. The bundle identifier stays `team.yourorbit.OrbitDictation` (frozen for install continuity), and behaviour-level files still track upstream. A `git merge upstream/main` may need manual resolution on the renamed app struct and module name.

</details>

## License

MIT. See [LICENSE](LICENSE). The original copyright belongs to Sophiie AI Pty Ltd; the Comet fork is copyright Justin Williames.
