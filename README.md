# Orbit Dictation

Orbit Dictation is a macOS menu-bar dictation app for the Orbit ecosystem. Hold a shortcut, speak, and the cleaned text drops into the app you are already using.

Powered by [Whispur](https://github.com/sophiie-ai/whispur). Orbit Dictation is an Orbit-branded fork that ships with a stricter cleanup prompt and the Orbit identity, while keeping internal modules aligned with Whispur for clean upstream merges.

> [get.yourorbit.team](https://get.yourorbit.team) · Download from the Orbit Downloads page

## Features

- Lives in the macOS menu bar instead of taking over your desktop
- Hold-to-talk or toggle-to-latch recording
- Multi-provider speech-to-text with local Apple dictation support
- Optional transcript cleanup with provider-selectable LLMs
- Paste-back into the active app with clipboard preservation
- Custom vocabulary and an editable cleanup prompt
- Local-first default path when you stick with Apple on-device transcription
- Sparkle-based auto-updates for signed releases

## Install

### From Orbit Downloads

The Orbit Downloads page on [get.yourorbit.team](https://get.yourorbit.team) hosts the latest signed DMG and links back to this repository.

### From GitHub Releases

Direct download: [latest release](https://github.com/justinwilliames-sketch/orbit-dictation/releases/latest).

### Build from source

```bash
git clone https://github.com/justinwilliames-sketch/orbit-dictation.git
cd orbit-dictation
brew install xcodegen create-dmg
make all
make run
```

## How it works

Hold the configured shortcut to record. On release, the audio is normalized to 16 kHz mono WAV, sent to the selected speech-to-text provider, optionally cleaned up by the configured LLM, and pasted into the frontmost app. Microphone permission and Accessibility permission are required for capture and paste-back respectively.

The Orbit Dictation cleanup prompt is intentionally strict: the LLM is treated as a text post-processor, never as an assistant, and must never act on the content of a transcript even when the transcript reads like an instruction. The full prompt is in `Sources/Pipeline/Prompts.swift`.

## Relationship to Whispur

Orbit Dictation is a fork of [Whispur](https://github.com/sophiie-ai/whispur) (MIT). Internal Swift modules and class names are kept aligned with upstream so improvements can flow back and forth cleanly. User-visible branding, the bundle identifier, the Sparkle update channel, the keychain service identifier, the application support directory, and the default cleanup prompt are Orbit-specific.

If you want the upstream version of this app, install Whispur from [whispur.app](https://whispur.app).

## License

MIT. See [LICENSE](LICENSE). The original copyright belongs to Sophiie AI Pty Ltd; the Orbit Dictation fork is copyright Justin Williames.
